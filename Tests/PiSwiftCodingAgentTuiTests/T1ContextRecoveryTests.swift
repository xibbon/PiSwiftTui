import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
@Suite("T1 recovery context edits", .serialized)
struct T1ContextRecoveryTests {
    // C1 / 02726086d: recovery emits one null edit for the assistant and one for its result.
    @Test(.timeLimit(.minutes(1)))
    func recoveryEditsReachUiAndRpcWithRefreshedContext() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let userId = manager.appendMessage(.user(UserMessage(content: .text("check status"))))
        let call = ToolCall(id: "truncated-call", name: "bash", arguments: ["command": AnyCodable("echo truncated")])
        var failed = t3aAssistant()
        failed.content = [.text(TextContent(text: "failed-attempt-text")), .toolCall(call)]
        failed.stopReason = .length
        let assistantId = manager.appendMessage(.assistant(failed))
        let resultId = manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: call.id, toolName: call.name,
            content: [.text(TextContent(text: "failed-tool-result"))], isError: true)))
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        registry.authStorage.setRuntimeApiKey("test", "test-key")
        let compact: HookHandler = { _, _ in
            SessionBeforeCompactResult(compaction: CompactionResult(summary: "recovery summary",
                firstKeptEntryId: userId, tokensBefore: 100))
        }
        let runner = HookRunner([LoadedHook(path: "<t1-recovery>", resolvedPath: "<t1-recovery>",
            handlers: ["session_before_compact": [compact]], isExtension: true)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(enabled: true)
        settings.retry = RetrySettings(enabled: false)
        session.settingsManager.applyOverrides(settings)
        session.refreshContext()
        let requests = LockedState<[[Message]]>([])
        session.agent.streamFn = { model, context, _ in
            requests.withLock { $0.append(context.messages) }
            var answer = t3aAssistant(model)
            answer.content = [.text(TextContent(text: "recovered-answer"))]
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: answer))
            stream.end(answer)
            return stream
        }
        let events = LockedState<[AgentSessionEvent]>([])
        let unsubscribe = session.subscribe { event in events.withLock { $0.append(event) } }
        defer { unsubscribe() }
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let host = InteractiveMode(session: session, tui: tui, editor: editor)
        host.renderInitialMessages()
        #expect(host.chatContainer.render(width: 120).joined().contains("failed-attempt-text"))

        let accepted = try await handleRpcCommand("prompt", ["message": "continue"], session, RpcOutput(write: { _ in }))
        #expect((accepted["data"] as? [String: String])?["disposition"] == "started")
        await session.waitForIdle()
        let emitted = events.withLock { $0 }
        let edits = emitted.compactMap { event -> SessionEntry? in
            guard case .entryAppended(let entry) = event, case .contextEdit = entry else { return nil }
            return entry
        }
        #expect(edits.compactMap { entry -> String? in
            guard case .contextEdit(let edit) = entry, edit.replacement == nil else { return nil }
            return edit.targetId
        } == [assistantId, resultId])
        // Replay the ordered host events, including both null edits and agent_settled.
        for event in emitted { host.handleSessionEvent(event) }
        let transcript = host.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(transcript.contains("recovered-answer"))
        // The visible transcript keeps raw history. Null edits change only model context.
        #expect(transcript.components(separatedBy: "failed-attempt-text").count - 1 == 1)
        #expect(transcript.components(separatedBy: "failed-tool-result").count - 1 == 1)
        let request = try #require(requests.withLock { $0.first })
        #expect(!request.contains { if case .assistant(let message) = $0 { return message.stopReason == .length }; return false })
        #expect(!request.contains { if case .toolResult(let result) = $0 { return result.toolCallId == call.id }; return false })
        #expect(manager.getEntry(assistantId) != nil)
        #expect(manager.getEntry(resultId) != nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-rpc-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventFile = directory.appendingPathComponent("events.jsonl")
        let responseFile = directory.appendingPathComponent("response.jsonl")
        let lines = edits.map { encodeSessionEventJSON(.entryAppended($0)) }
        try (lines.joined(separator: "\n") + "\n").write(to: eventFile, atomically: true, encoding: .utf8)
        try (encodeRpcMessagesResponse("req_1", messages: session.messages) + "\n")
            .write(to: responseFile, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("rpc.sh")
        try #"""
        #!/bin/sh
        IFS= read -r request
        cat "$T1_RECOVERY_EVENTS"
        cat "$T1_RECOVERY_RESPONSE"
        exit 0
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = RpcClient(options: RpcClientOptions(cliPath: script.path,
            env: ["T1_RECOVERY_EVENTS": eventFile.path, "T1_RECOVERY_RESPONSE": responseFile.path]))
        let received = LockedState<[[String: AnyCodable]]>([])
        let removeListener = await client.onEvent { event in
            if case .unknown(let object) = event { received.withLock { $0.append(object) } }
        }
        try await client.start()
        do {
            let messages = try await client.getMessages()
            #expect(!messages.contains { if case .assistant(let value) = $0 { return value.stopReason == .length }; return false })
            #expect(!messages.contains { if case .toolResult(let value) = $0 { return value.toolCallId == call.id }; return false })
            #expect(messages.contains { message in
                guard case .assistant(let value) = message else { return false }
                return value.content.contains { block in
                    if case .text(let text) = block { return text.text == "recovered-answer" }
                    return false
                }
            })
            let wireEdits = received.withLock { $0 }
            #expect(wireEdits.count == 2)
            let targets = wireEdits.compactMap { object -> String? in
                #expect(object["type"]?.value as? String == "entry_appended")
                let entry = object["entry"]?.value as? [String: Any]
                #expect(entry?["type"] as? String == "context_edit")
                #expect(entry?["replacement"] is NSNull)
                return entry?["targetId"] as? String
            }
            #expect(targets == [assistantId, resultId])
        } catch {
            removeListener()
            await client.stop()
            throw error
        }
        removeListener()
        await client.stop()
    }
}
