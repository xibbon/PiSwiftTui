import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI
@testable import PiSwiftCodingAgentTui

@MainActor @Suite("PT0 CLI session lifecycle", .serialized)
struct PT0SessionLifecycleTests {
    @Test(arguments: ["interactive", "print", "rpc"])
    func normalEndDisposesOnce(_ mode: String) async {
        await checkEnd(mode: mode, end: "normal")
    }

    @Test(arguments: ["interactive", "print", "rpc"])
    func errorEndDisposesOnce(_ mode: String) async {
        await checkEnd(mode: mode, end: "error")
    }

    @Test(arguments: ["interactive", "print", "rpc"])
    func signalEndDisposesOnce(_ mode: String) async {
        await checkEnd(mode: mode, end: "signal")
    }

    private func checkEnd(mode: String, end: String) async {
        let settings = SettingsManager.inMemory()
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let trace = LockedState<[String]>([])
        let runner = HookRunner([LoadedHook(path: "<pt0>", resolvedPath: "<pt0>",
            handlers: ["session_shutdown": [{ _, _ in
                trace.withLock { $0.append("shutdown") }
                return nil
            }]], isExtension: true)], "/tmp", manager, registry)
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: manager, settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings)),
            hookRunner: runner, modelRegistry: registry
        ))
        let id = session.sessionId
        let cleaned = LockedState<[String]>([])
        let unregister = registerSessionResourceCleanup { cleanedID in
            if cleanedID == id {
                cleaned.withLock { $0.append(id) }
                trace.withLock { $0.append("dispose") }
            }
        }
        defer { unregister() }
        let lifecycle = SessionRunLifecycle()
        lifecycle.install(session)
        if mode == "interactive" {
            if end == "error" {
                // A startup error occurs before the interactive renderer exists.
                await lifecycle.shutdownAndDispose()
            } else {
                let interactive = InteractiveMode(session: session, version: "PT0")
                await interactive.performShutdown(fromSignal: end == "signal")
                lifecycle.disposeOnce()
            }
        } else if mode == "print" {
            if end != "signal" {
                if end == "error" {
                    let model = session.agent.state.model
                    var message = AssistantMessage(content: [], api: model.api, provider: model.provider,
                        model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
                            totalTokens: 0), stopReason: .error)
                    message.errorMessage = "PT0 failure"
                    session.agent.messages = [.assistant(message)]
                }
                let status = try? await runPrintMode(session, .text, [], output: PrintModeOutput(
                    writeString: { _ in }, writeError: { _ in }, flush: {}
                ))
                #expect(status == (end == "error" ? 1 : 0))
            }
            if end == "signal" {
                await Task.detached { await lifecycle.shutdownAndDispose() }.value
            } else {
                await lifecycle.shutdownAndDispose()
            }
        } else {
            if end != "signal" {
                let input = LockedState(end == "error" ? ["{\"type\":\"unknown\"}"] : [String]())
                await runRpcMode(session, output: RpcOutput(write: { _ in }), readInputLine: {
                    input.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                })
            }
            if end == "signal" {
                await Task.detached { await lifecycle.shutdownAndDispose() }.value
            } else {
                await lifecycle.shutdownAndDispose()
            }
        }
        // A deferred owner cleanup must be harmless after a direct exit path.
        lifecycle.disposeOnce()
        await lifecycle.shutdownAndDispose()
        #expect(cleaned.withLock { $0 } == [id], "\(mode) \(end)")
        #expect(trace.withLock { $0 } == ["shutdown", "dispose"])
    }
}
