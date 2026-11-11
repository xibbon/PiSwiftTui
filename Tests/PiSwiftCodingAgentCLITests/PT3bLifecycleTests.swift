import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

@Suite("PT3b current session lifecycle")
struct PT3bLifecycleTests {
    @Test func replacementDisposesOldThenOwnerDisposesCurrentOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-pt3b-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstManager = SessionManager.create(directory.path, directory.path)
        let nextManager = SessionManager.create(directory.path, directory.path)
        _ = nextManager.appendMessage(.user(UserMessage(content: .text("next"))))
        let nextPath = try #require(nextManager.getSessionFile())
        let first = makeSession(firstManager)
        let next = makeSession(nextManager)
        let cleanup = LockedState<[String]>([])
        let firstID = first.sessionManager.getSessionId()
        let nextID = next.sessionManager.getSessionId()
        let ids = Set([firstID, nextID])
        let unregister = registerSessionResourceCleanup { id in
            if let id, ids.contains(id) { cleanup.withLock { $0.append(id) } }
        }
        defer { unregister() }
        let lifecycle = SessionRunLifecycle()
        lifecycle.install(first)
        let runtime = AgentSessionRuntime(agentDir: directory.path,
            factory: { _ in next }, initialSession: first)
        lifecycle.installRuntime(runtime)
        _ = try await runtime.switchSessionRebinding(nextPath)
        await lifecycle.shutdownAndDispose()
        lifecycle.disposeOnce()
        #expect(cleanup.withLock { $0 } == [firstID, nextID])
    }

    private func makeSession(_ manager: SessionManager) -> AgentSession {
        let settings = SettingsManager.inMemory()
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        return AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: manager, settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(
                cwd: manager.getCwd(), settingsManager: settings)),
            modelRegistry: registry
        ))
    }
}
