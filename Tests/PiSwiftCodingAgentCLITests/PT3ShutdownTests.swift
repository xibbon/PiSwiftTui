import Foundation
import PiSwiftAI
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private actor PT3SaveGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class PT3DelayedAuthBackend: AuthStorageBackend {
    let base: FileAuthStorageBackend
    let gate = PT3SaveGate()
    let started = AsyncStream<Void>.makeStream()
    let trace = LockedState<[String]>([])

    init(_ path: String) { base = FileAuthStorageBackend(path) }

    func withLock<R: Sendable>(_ body: @Sendable (String?) throws -> AuthStorageLockResult<R>) throws -> R {
        try base.withLock(body)
    }

    func withLockAsync<R: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<R>
    ) async throws -> R {
        let value = try await base.withLockAsync { current in
            let result = try await body(current)
            if result.next != nil {
                self.started.continuation.yield()
                await self.gate.wait()
            }
            return result
        }
        trace.withLock { $0.append("saved") }
        return value
    }
}

@Suite("PT3 shutdown")
struct PT3ShutdownTests {
    // v1.5.2 7a53c310a, suite/regressions/9124-runtime-dispose-tool-settlement.test.ts.
    @Test("CLI lifecycle records an aborted tool result before disposal")
    func lifecycleSettlesAbortedTool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-tool-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let started = AsyncStream<Void>.makeStream()
        struct AbortedTool: LocalizedError { var errorDescription: String? { "Operation aborted" } }
        let tool = AgentTool(label: "Wait", name: "wait", description: "Wait until aborted",
            parameters: ["type": AnyCodable("object")]) { _, _, signal, _ in
                started.continuation.yield()
                while signal?.isCancelled != true {
                    try await Task.sleep(for: .milliseconds(5))
                }
                throw AbortedTool()
            }
        let requests = LockedState(0)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model,
            tools: [tool]), streamFn: { model, _, _ in
                let first = requests.withLock { count in count += 1; return count == 1 }
                let events = AssistantMessageEventStream()
                events.push(.done(reason: first ? .toolUse : .stop, message: AssistantMessage(
                    content: first ? [.toolCall(ToolCall(id: "wait-1", name: "wait", arguments: [:]))]
                        : [.text(TextContent(text: "done"))],
                    api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: first ? .toolUse : .stop)))
                return events
            }, getApiKey: { _ in "test" }))
        let manager = SessionManager.create(directory.path, directory.path)
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey(model.provider, "test")
        let session = AgentSession(config: AgentSessionConfig(agent: agent,
            sessionManager: manager, settingsManager: .inMemory(),
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path,
                settingsManager: .inMemory())), modelRegistry: ModelRegistry(auth)))
        let lifecycle = SessionRunLifecycle()
        lifecycle.install(session)
        let prompt = Task { try? await session.prompt("run tool") }
        var startedEvents = started.stream.makeAsyncIterator()
        #expect(await startedEvents.next() != nil)
        await lifecycle.shutdownAndDispose()
        await prompt.value
        let file = try #require(manager.getSessionFile())
        let messages = SessionManager.open(file).getEntries().compactMap { entry -> AgentMessage? in
            if case .message(let value) = entry, value.message.role != "system" { return value.message }
            return nil
        }
        #expect(messages.map(\.role) == ["user", "assistant", "toolResult", "assistant"])
        if messages.count > 2, case .toolResult(let result) = messages[2] {
            #expect(result.isError)
        }
    }

    // v1.5.2 b2cb62923, runtime-credentials.test.ts:76 and
    // suite/regressions/11692-dispose-waits-for-oauth-refresh.test.ts.
    @Test("CLI lifecycle waits for the pending credential file write")
    func lifecycleSettlesCredentialWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pt3-auth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authPath = directory.appendingPathComponent("auth.json").path
        let backend = PT3DelayedAuthBackend(authPath)
        let auth = AuthStorage(storage: backend)
        auth.set("xai", credential: .oauth(OAuthCredential(access: "old", refresh: "old", expires: 0)))
        auth.setOAuthOverridesForTesting(OAuthOverrides(getOAuthApiKeyWithSignal: { _, _, _ in
            (OAuthCredentials(refresh: "new-refresh", access: "new-access",
                expires: Date().timeIntervalSince1970 * 1000 + 3_600_000), "new-access")
        }))
        let manager = SessionManager.inMemory(directory.path)
        let registry = ModelRegistry(auth)
        let runner = HookRunner([LoadedHook(path: "<pt3>", resolvedPath: "<pt3>",
            handlers: ["session_shutdown": [{ _, _ in
                backend.trace.withLock { $0.append("shutdown") }
                return nil
            }]], isExtension: true)], directory.path, manager, registry)
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: manager, settingsManager: .inMemory(),
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path,
                settingsManager: .inMemory())), hookRunner: runner, modelRegistry: registry
        ))
        let lifecycle = SessionRunLifecycle()
        lifecycle.install(session)
        let disposed = AsyncStream<Void>.makeStream()
        let unregister = registerSessionResourceCleanup { id in
            if id == session.sessionId {
                backend.trace.withLock { $0.append("dispose") }
                disposed.continuation.yield()
            }
        }
        defer { unregister() }
        let refresh = Task { await auth.getApiKey("xai") }
        var started = backend.started.stream.makeAsyncIterator()
        #expect(await started.next() != nil)
        let finished = LockedState(false)
        let closing = Task {
            await lifecycle.shutdownAndDispose()
            finished.withLock { $0 = true }
        }
        var disposal = disposed.stream.makeAsyncIterator()
        #expect(await disposal.next() != nil)
        #expect(!finished.withLock { $0 })
        await backend.gate.release()
        await closing.value
        #expect(await refresh.value == "new-access")
        guard case .oauth(let saved) = AuthStorage(authPath).get("xai") else {
            Issue.record("Credential was not saved")
            return
        }
        #expect(saved.refresh == "new-refresh")
        #expect(backend.trace.withLock { $0 } == ["shutdown", "dispose", "saved"])
    }
}
