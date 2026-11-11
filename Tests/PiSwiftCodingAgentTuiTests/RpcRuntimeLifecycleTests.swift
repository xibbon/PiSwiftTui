import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

@Suite struct RpcRuntimeLifecycleTests {
    @Test func switchSessionRebindsFollowingCommands() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-rpc-rebind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionDirectory = directory.appendingPathComponent("sessions").path
        let initial = t3aSession(manager: SessionManager.create(directory.path, sessionDirectory))
        let targetManager = SessionManager.create(directory.path, sessionDirectory)
        targetManager.appendMessage(.user(UserMessage(content: .text("target"))))
        let target = t3aSession(manager: targetManager)
        let runtime = AgentSessionRuntime(agentDir: directory.path,
            factory: { _ in target }, initialSession: initial)
        defer { runtime.dispose() }
        let targetPath = try #require(targetManager.getSessionFile())
        let commands = LockedState([
            "{\"type\":\"switch_session\",\"id\":\"switch\",\"sessionPath\":\"\(targetPath)\"}",
            "{\"type\":\"get_state\",\"id\":\"state\"}",
        ])
        let responses = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(initial, runtime: runtime,
            output: RpcOutput(write: { response in
                responses.withLock { $0.append(response.mapValues(AnyCodable.init)) }
            }),
            readInputLine: { commands.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        let sent = responses.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent.first?["success"]?.value as? Bool == true)
        #expect((sent.first?["data"]?.value as? [String: Any])?["cancelled"] as? Bool == false)
        #expect((sent.last?["data"]?.value as? [String: Any])?["sessionId"] as? String == target.sessionId)
    }

    @Test func replacementSessionStartSeesBoundUiExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-rpc-start-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("sessions").path
        let first = t3aSession(manager: SessionManager.create(directory.path, sessions))
        let nextManager = SessionManager.create(directory.path, sessions)
        nextManager.appendMessage(.user(UserMessage(content: .text("next"))))
        let path = try #require(nextManager.getSessionFile())
        let count = LockedState(0)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([LoadedHook(path: "<start-ui>", resolvedPath: "<start-ui>",
            handlers: ["session_start": [{ _, context in
                count.withLock { $0 += 1 }
                await context.ui.notify("bound-before-start", .info)
                return nil
            }]], isExtension: true)], directory.path, nextManager, registry)
        let next = t3aSession(manager: nextManager, registry: registry, runner: runner)
        let runtime = AgentSessionRuntime(agentDir: directory.path,
            factory: { _ in next }, initialSession: first)
        defer { runtime.dispose() }
        let lines = LockedState([
            "{\"type\":\"switch_session\",\"id\":\"switch\",\"sessionPath\":\"\(path)\"}",
            "{\"type\":\"get_state\",\"id\":\"state\"}",
        ])
        let output = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(first, runtime: runtime,
            output: RpcOutput(write: { item in
                output.withLock { $0.append(item.mapValues(AnyCodable.init)) }
            }), readInputLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        let sent = output.withLock { $0 }
        #expect(count.withLock { $0 } == 1)
        let notice = try #require(sent.firstIndex { $0["method"]?.value as? String == "notify" })
        let response = try #require(sent.firstIndex { $0["id"]?.value as? String == "switch" })
        #expect(notice < response)
        #expect(sent[notice]["message"]?.value as? String == "bound-before-start")
        #expect((sent.last?["data"]?.value as? [String: Any])?["sessionId"] as? String == next.sessionId)
    }

    @Test func extensionShutdownDuringStartEndsInputLoop() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([LoadedHook(path: "<rpc-shutdown>", resolvedPath: "<rpc-shutdown>",
            handlers: ["session_start": [{ _, context in
                context.shutdown()
                return nil
            }]], isExtension: true)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let reads = LockedState(0)
        let responses = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(session,
            output: RpcOutput(write: { response in
                responses.withLock { $0.append(response.mapValues(AnyCodable.init)) }
            }),
            readInputLine: {
                reads.withLock { $0 += 1 }
                return reads.withLock { $0 } == 1 ? "{\"type\":\"get_state\",\"id\":\"late\"}" : nil
            })
        #expect(responses.withLock { $0.isEmpty })
    }

    @Test func extensionCommandResponsePrecedesShutdown() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let command = RegisteredCommand(name: "leave", handler: { _, context in
            context.shutdown()
        })
        let runner = HookRunner([LoadedHook(path: "<rpc-command-shutdown>",
            resolvedPath: "<rpc-command-shutdown>", handlers: [:],
            commands: ["leave": command], isExtension: true)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let inputs = LockedState(["{\"type\":\"prompt\",\"id\":\"active\",\"message\":\"/leave\"}"])
        let responses = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(session, output: RpcOutput(write: { response in
            responses.withLock { $0.append(response.mapValues(AnyCodable.init)) }
        }), readInputLine: { inputs.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        let sent = responses.withLock { $0 }
        #expect(sent.contains { $0["id"]?.value as? String == "active" && $0["success"]?.value as? Bool == true })
    }

    @Test("waits for a command that arrives before an idle shutdown request is processed")
    func idleShutdownWaitsForQueuedCommand() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let request = LockedState<(@Sendable () -> Void)?>(nil)
        let commandStarted = LockedState(false)
        let command = RegisteredCommand(name: "slow", handler: { _, _ in
            commandStarted.withLock { $0 = true }
            try await Task.sleep(for: .milliseconds(50))
        })
        let runner = HookRunner([LoadedHook(path: "<idle-shutdown>", resolvedPath: "<idle-shutdown>",
            handlers: ["session_start": [{ _, context in
                request.withLock { $0 = { context.shutdown() } }
                return nil
            }]], commands: ["slow": command], isExtension: true)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let scheduled = LockedState<[@Sendable () -> Void]>([])
        let bridge = RpcShutdownBridge(scheduleCheck: { check in
            scheduled.withLock { $0.append(check) }
        })
        let output = LockedState<[[String: AnyCodable]]>([])
        let inputGate = DispatchSemaphore(value: 0)
        defer { bridge.finishInput(); inputGate.signal() }
        let mode = Task {
            await runRpcMode(session, shutdownBridge: bridge,
                output: RpcOutput(write: { response in
                    output.withLock { $0.append(response.mapValues(AnyCodable.init)) }
                }), readInputLine: {
                    inputGate.wait()
                    return nil
                })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while request.withLock({ $0 == nil }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requestShutdown = try #require(request.withLock { $0 })
        requestShutdown()
        #expect(bridge.enqueue("{\"type\":\"prompt\",\"id\":\"s\",\"message\":\"/slow\"}"))
        while !commandStarted.withLock({ $0 }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(commandStarted.withLock { $0 })
        let check = try #require(scheduled.withLock { $0.first })
        check()
        await mode.value
        let sent = output.withLock { $0 }
        #expect(sent.contains { $0["id"]?.value as? String == "s" && $0["success"]?.value as? Bool == true })
    }

    @Test func replacementStartShutdownWritesSwitchResponseFirst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-rpc-shutdown-switch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstManager = SessionManager.create(directory.path, directory.path)
        let nextManager = SessionManager.create(directory.path, directory.path)
        nextManager.appendMessage(.user(UserMessage(content: .text("target"))))
        let path = try #require(nextManager.getSessionFile())
        let first = t3aSession(manager: firstManager)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([LoadedHook(path: "<start-shutdown>", resolvedPath: "<start-shutdown>",
            handlers: ["session_start": [{ _, context in
                context.shutdown()
                return nil
            }]], isExtension: true)], directory.path, nextManager, registry)
        let next = t3aSession(manager: nextManager, registry: registry, runner: runner)
        let bridge = RpcShutdownBridge()
        let runtime = AgentSessionRuntime(agentDir: directory.path, factory: { _ in
            runner.setShutdownHandler { bridge.request() }
            return next
        }, initialSession: first)
        defer { runtime.dispose() }
        let input = LockedState([
            "{\"type\":\"switch_session\",\"id\":\"switch\",\"sessionPath\":\"\(path)\"}",
        ])
        let responses = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(first, runtime: runtime, shutdownBridge: bridge,
            output: RpcOutput(write: { response in
                responses.withLock { $0.append(response.mapValues(AnyCodable.init)) }
            }), readInputLine: { input.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        let sent = responses.withLock { $0 }
        #expect(sent.contains { $0["id"]?.value as? String == "switch" && $0["success"]?.value as? Bool == true })
    }
}
