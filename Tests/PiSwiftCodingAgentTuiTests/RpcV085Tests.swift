import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

@Suite struct RpcV085Tests {
    @Test func messageUpdatesRetainCumulativeUsageAndToolIdentity() throws {
        let event = try #require(decodeAgentEvent([
            "type": "message_update",
            "assistantMessageEvent": ["type": "toolcall_start", "contentIndex": 2, "id": "call-123", "toolName": "bash"],
            "usage": ["input": 12, "output": 4, "cacheRead": 30, "cacheWrite": 2, "totalTokens": 48,
                      "cost": ["input": 0.1, "output": 0.2, "cacheRead": 0.01, "cacheWrite": 0.02, "total": 0.33]],
        ]))
        #expect(event.message == nil)
        #expect(event.assistantMessageEvent == "toolcall_start")
        #expect(event.assistantMessageContentIndex == 2)
        #expect(event.assistantMessageToolCallId == "call-123")
        #expect(event.assistantMessageToolName == "bash")
        #expect(event.toolCallId == "call-123")
        #expect(event.toolName == "bash")
        #expect(event.usage?.input == 12)
        #expect(event.usage?.output == 4)
        #expect(event.usage?.cacheRead == 30)
        #expect(event.usage?.cacheWrite == 2)
        #expect(event.usage?.totalTokens == 48)
        #expect(event.usage?.cost.total == 0.33)
    }

    @Test func libraryEncoderFieldsSurviveRpcClientDecoding() throws {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let message = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call-roundtrip", name: "read", arguments: [:]))],
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 15, output: 6, cacheRead: 4, cacheWrite: 0, totalTokens: 25), stopReason: .toolUse
        )
        let payload = encodeSessionEvent(.agent(.messageUpdate(message: .assistant(message), assistantMessageEvent: .toolCallStart(contentIndex: 0, partial: message))))
        let event = try #require(decodeAgentEvent(payload))
        #expect(event.assistantMessageEvent == "toolcall_start")
        #expect(event.assistantMessageToolCallId == "call-roundtrip")
        #expect(event.assistantMessageToolName == "read")
        #expect(event.usage?.totalTokens == 25)
    }

    @Test func usageIsDecodedForTextAndThinkingFrames() throws {
        for type in ["text_delta", "thinking_delta", "tool_call_delta", "tool_call_end"] {
            let event = try #require(decodeAgentEvent([
                "type": "message_update",
                "assistantMessageEvent": ["type": type, "contentIndex": 0, "delta": "part"],
                "usage": ["input": 6, "output": 3, "totalTokens": 9],
            ]))
            #expect(event.assistantMessageEvent == type)
            #expect(event.assistantMessageDelta == "part")
            #expect(event.usage?.totalTokens == 9)
        }
        #expect(decodeAgentEvent(["type": "message_update", "assistantMessageEvent": ["type": "text_delta"]])?.usage == nil)
    }

    @Test func clientClearQueueSendsCommandAndReturnsBothLists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("rpc.sh")
        try #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *clear_queue*) printf '%s\n' '{"id":"req_1","type":"response","command":"clear_queue","success":true,"data":{"steering":["steer one","steer two"],"followUp":["later"]}}'; exit 0 ;;
            *) exit 4 ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = RpcClient(options: RpcClientOptions(cliPath: script.path, cwd: dir.path))
        try await client.start()
        do {
            let result = try await client.clearQueue()
            #expect(result.steering == ["steer one", "steer two"])
            #expect(result.followUp == ["later"])
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    @Test func clearQueueRequestReturnsAndRemovesQueuedMessages() async throws {
        let session = makeRpcV085Session()
        defer { session.dispose() }
        session.steer("steer one")
        session.followUp("follow one")
        let response = try await handleRpcCommand("clear_queue", ["id": "clear-1"], session, RpcOutput(write: { _ in }))
        #expect(response["success"] as? Bool == true)
        #expect(response["id"] as? String == "clear-1")
        let data = try #require(response["data"] as? [String: Any])
        #expect(data["steering"] as? [String] == ["steer one"])
        #expect(data["followUp"] as? [String] == ["follow one"])
        #expect(session.pendingMessageCount == 0)
        #expect(session.clearQueue().steering.isEmpty)
    }

    @Test func rpcSteerAndFollowUpRunInputHooksWithRpcSource() async throws {
        let sources = LockedState<[String]>([])
        let handler: HookHandler = { event, _ in
            guard let input = event as? InputEvent else { return nil }
            sources.withLock { $0.append(input.source.rawValue) }
            return InputEventResult.transform(text: "hooked: \(input.text)")
        }
        let session = makeRpcV085Session(handler: handler, eventName: "input")
        defer { session.dispose() }
        let output = RpcOutput(write: { _ in })
        let steer = try await handleRpcCommand("steer", ["message": "first"], session, output)
        let follow = try await handleRpcCommand("follow_up", ["message": "second"], session, output)
        #expect(steer["success"] as? Bool == true)
        #expect(follow["success"] as? Bool == true)
        #expect(sources.withLock { $0 } == ["rpc", "rpc"])
        let queued = session.clearQueue()
        #expect(queued.steering == ["hooked: first"])
        #expect(queued.followUp == ["hooked: second"])
    }

    @Test func abortRequestCancelsManualCompaction() async throws {
        let started = LockedState(false)
        let handler: HookHandler = { event, _ in
            guard let event = event as? SessionBeforeCompactEvent else { return nil }
            started.withLock { $0 = true }
            while event.signal?.isCancelled != true {
                try await Task.sleep(for: .milliseconds(5))
            }
            return SessionBeforeCompactResult(cancel: true)
        }
        let session = makeRpcV085Session(handler: handler)
        defer { session.dispose() }
        let output = RpcOutput(write: { _ in })
        let compact = Task {
            do {
                _ = try await handleRpcCommand("compact", [:], session, output)
                return false
            } catch { return true }
        }
        for _ in 0..<400 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.withLock { $0 })
        let response = try await handleRpcCommand("abort", [:], session, output)
        #expect(response["success"] as? Bool == true)
        #expect(await compact.value)
        #expect(!session.isCompacting)
    }
}

private func makeRpcV085Session(handler: HookHandler? = nil, eventName: String = "session_before_compact") -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let manager = SessionManager.inMemory()
    for text in ["first", "second"] {
        manager.appendMessage(.user(UserMessage(content: .text(text))))
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: text + " reply"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 100, output: 100, cacheRead: 0, cacheWrite: 0, totalTokens: 200), stopReason: .stop
        )))
    }
    let settings = SettingsManager.inMemory()
    var values = Settings()
    values.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
    settings.applyOverrides(values)
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: [])))
    agent.messages = manager.buildSessionContext().messages
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let registry = ModelRegistry(auth)
    let runner = handler.map { handler in
        let runner = HookRunner([LoadedHook(path: "<rpc-test>", resolvedPath: "<rpc-test>", handlers: [eventName: [handler]], isExtension: eventName == "input")], "/tmp", manager, registry)
        runner.initialize(getModel: { model }, hasUI: false)
        return runner
    }
    return AgentSession(config: AgentSessionConfig(
        agent: agent, sessionManager: manager, settingsManager: settings,
        resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings)),
        hookRunner: runner, modelRegistry: registry
    ))
}
