import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// rpc-prompt-response-semantics.test.ts and modes/rpc/rpc-client.ts, v0.99.1.
@Suite struct T3aRpcTests {
    private func interceptedSession(_ handler: @escaping HookHandler) -> AgentSession {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([LoadedHook(path: "<t3a>", resolvedPath: "<t3a>", handlers: ["input": [handler]], isExtension: true)], "/tmp", manager, registry)
        return t3aSession(manager: manager, registry: registry, runner: runner)
    }

    @Test func promptReturnsStartedOnceAndLateFailureHasNoSecondResponse() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        session.agent.streamFn = { model, _, _ in
            let stream = AssistantMessageEventStream()
            var message = t3aAssistant(model)
            message.stopReason = .error
            message.errorMessage = "late failure"
            stream.push(.error(reason: .error, error: message))
            stream.end(message)
            return stream
        }
        let responses = LockedState<[[String: AnyCodable]]>([])
        await dispatchRpcCommand("prompt", ["id": "start", "message": "hello"], session,
            RpcOutput(write: { response in responses.withLock { $0.append(response.mapValues(AnyCodable.init)) } }))
        await session.waitForIdle()
        let sent = responses.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?["success"]?.value as? Bool == true)
        #expect((sent.first?["data"]?.value as? [String: String]) == ["disposition": "started"])
    }

    @Test func inputHandledPromptStartsNoRunAndHasRpcSource() async throws {
        let inputs = LockedState<[InputEvent]>([])
        let session = interceptedSession { event, _ in
            if let input = event as? InputEvent { inputs.withLock { $0.append(input) } }
            return InputEventResult.handled
        }
        defer { session.dispose() }
        let response = try await handleRpcCommand("prompt", ["message": "A", "streamingBehavior": "followUp"], session, RpcOutput(write: { _ in }))
        #expect((response["data"] as? [String: String]) == ["disposition": "handled"])
        #expect(!session.isStreaming)
        #expect(inputs.withLock { $0.first?.source } == .rpc)
        #expect(inputs.withLock { $0.first?.streamingBehavior } == nil)
    }

    @Test func preflightFailureHasNoSuccessResponse() async {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let session = t3aSession(registry: registry)
        defer { session.dispose() }
        let responses = LockedState<[[String: AnyCodable]]>([])
        await dispatchRpcCommand("prompt", ["id": "preflight", "message": "no credentials"], session,
            RpcOutput(write: { response in responses.withLock { $0.append(response.mapValues(AnyCodable.init)) } }))
        let sent = responses.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?["id"]?.value as? String == "preflight")
        #expect(sent.first?["success"]?.value as? Bool == false)
        #expect((sent.first?["error"]?.value as? String)?.contains("API key") == true)
        #expect(!session.isStreaming)
    }

    // #9803: A is consumed while the handler independently queues B.
    @Test func handledInputKeepsIndependentQueuedMessage() async throws {
        for command in ["steer", "follow_up"] {
            let box = LockedState<AgentSession?>(nil)
            let session = interceptedSession { event, _ in
                guard let input = event as? InputEvent, input.text == "A" else { return InputEventResult.continue }
                if command == "steer" { box.withLock { $0 }?.steer("B") }
                else { box.withLock { $0 }?.followUp("B") }
                return InputEventResult.handled
            }
            box.withLock { $0 = session }
            defer { session.dispose(); box.withLock { $0 = nil } }
            let streams = LockedState<AssistantMessageEventStream?>(nil)
            session.modelRegistry.authStorage.setRuntimeApiKey("test", "test")
            session.agent.streamFn = { _, _, _ in
                let stream = AssistantMessageEventStream()
                streams.withLock { $0 = stream }
                return stream
            }
            _ = try await handleRpcCommand("prompt", ["message": "start"], session, RpcOutput(write: { _ in }))
            for _ in 0..<100 where streams.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(5)) }
            let stream = try #require(streams.withLock { $0 })
            let responses = LockedState<[[String: AnyCodable]]>([])
            await dispatchRpcCommand(command, ["id": "A", "message": "A"], session,
                RpcOutput(write: { response in responses.withLock { $0.append(response.mapValues(AnyCodable.init)) } }))
            let sent = responses.withLock { $0 }
            #expect(sent.count == 1)
            #expect(sent.first?["id"]?.value as? String == "A")
            #expect((sent.first?["data"]?.value as? [String: String]) == ["disposition": "handled"])
            let queue = session.clearQueue()
            #expect(command == "steer" ? queue.steering == ["B"] : queue.followUp == ["B"])
            let message = t3aAssistant()
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            await session.waitForIdle()
        }
    }

    @Test func steerAndFollowUpReturnHandledOrTransformedQueued() async throws {
        for command in ["steer", "follow_up"] {
            let session = interceptedSession { event, _ in
                guard let input = event as? InputEvent else { return nil }
                return input.text == "A" ? InputEventResult.handled : InputEventResult.transform(text: "B")
            }
            defer { session.dispose() }
            let handled = try await handleRpcCommand(command, ["message": "A"], session, RpcOutput(write: { _ in }))
            #expect((handled["data"] as? [String: String]) == ["disposition": "handled"])
            let queued = try await handleRpcCommand(command, ["message": "transform"], session, RpcOutput(write: { _ in }))
            #expect((queued["data"] as? [String: String]) == ["disposition": "queued"])
            let queue = session.clearQueue()
            #expect(command == "steer" ? queue.steering == ["B"] : queue.followUp == ["B"])
        }
    }

    @Test func streamingPromptForwardsFollowUpAndReturnsQueued() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        let activeStream = LockedState<AssistantMessageEventStream?>(nil)
        session.agent.streamFn = { _, _, _ in
            let stream = AssistantMessageEventStream()
            activeStream.withLock { $0 = stream }
            return stream
        }
        let output = RpcOutput(write: { _ in })
        let first = try await handleRpcCommand("prompt", ["message": "first"], session, output)
        #expect((first["data"] as? [String: String])?["disposition"] == "started")
        for _ in 0..<100 where !session.isStreaming { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isStreaming)
        for _ in 0..<100 where activeStream.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(5)) }
        let stream = try #require(activeStream.withLock { $0 })
        let queued = try await handleRpcCommand("prompt", ["message": "later", "streamingBehavior": "followUp"], session, output)
        #expect((queued["data"] as? [String: String]) == ["disposition": "queued"])
        #expect(session.clearQueue().followUp == ["later"])
        let response = t3aAssistant()
        stream.push(.done(reason: .stop, message: response))
        stream.end(response)
        await session.waitForIdle()
    }

    @Test(arguments: ["prompt", "steer", "follow_up"])
    func clientSendsStreamingBehaviorImagesAndReturnsDispositions(command: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3a-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("rpc.sh")
        try #"""
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$T3A_REQUEST_LOG"
          printf '{"id":"req_1","type":"response","command":"%s","success":true,"data":{"disposition":"%s"}}\n' "$T3A_COMMAND" "$T3A_DISPOSITION"
          exit 0
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let requestLog = dir.appendingPathComponent("requests.jsonl")
        let disposition = command == "steer" ? "handled" : "queued"
        let client = RpcClient(options: RpcClientOptions(cliPath: script.path,
            env: ["T3A_REQUEST_LOG": requestLog.path, "T3A_COMMAND": command, "T3A_DISPOSITION": disposition]))
        try await client.start()
        do {
            let images = [ImageContent(data: "base64", mimeType: "image/png")]
            switch command {
            case "prompt": #expect(try await client.prompt("later", images: images, streamingBehavior: .followUp) == .queued)
            case "steer": #expect(try await client.steer("later", images: images) == .handled)
            default: #expect(try await client.followUp("later", images: images) == .queued)
            }
            let data = try Data(contentsOf: requestLog)
            let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(request["type"] as? String == command)
            #expect(request["message"] as? String == "later")
            #expect(request["streamingBehavior"] as? String == (command == "prompt" ? "followUp" : nil))
            #expect((request["images"] as? [[String: String]]) == [["data": "base64", "mimeType": "image/png"]])
        } catch { await client.stop(); throw error }
        await client.stop()
    }
}
