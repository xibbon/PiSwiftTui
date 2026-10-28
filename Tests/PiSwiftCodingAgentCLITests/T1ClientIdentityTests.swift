// Upstream v1.4.0 core/client-identity.ts and core/sdk.ts: read identity for each request.
import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private struct T1IdentityHTTPClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        let body = """
        data: {"id":"t1","object":"chat.completion.chunk","created":0,"model":"chat","choices":[{"index":0,"delta":{"role":"assistant","content":"summary"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(body.utf8))
    }
}

private struct T1IdentityFixture: Sendable {
    let directory: URL
    let provider = "t1-identity-\(UUID())"
    let settings: SettingsManager
    let policy: CLIClientIdentityPolicy
    let registry: ModelRegistry
    let calls = LockedState<[SimpleStreamOptions]>([])
    let requests = LockedState<[URLRequest]>([])
    let sessionManager: SessionManager
    let agentBox = LockedState<Agent?>(nil)

    init(registryIdentity: ClientIdentityProvider? = nil, baseUrl: String = "https://openrouter.ai/api/v1") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-identity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = Settings()
        values.enableInstallTelemetry = false
        values.cacheWarming = .off
        values.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
        settings = .inMemory(values)
        policy = CLIClientIdentityPolicy(settings)
        let policy = policy
        registry = ModelRegistry(.inMemory([provider: .apiKey(ApiKeyCredential(key: "test-key"))]),
            directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false,
            clientIdentityProvider: { mergeClientIdentity(policy.identity(), registryIdentity?()) })
        sessionManager = .inMemory(directory.path)
        let calls = calls
        let http = T1IdentityHTTPClient(requests: requests)
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: baseUrl, streamSimple: { model, context, options in
                var options = options ?? SimpleStreamOptions()
                calls.withLock { $0.append(options) }
                options.httpClient = http
                do { return try PiSwiftAI.streamSimple(model: model, context: context, options: options) }
                catch {
                    Issue.record(error)
                    let failed = AssistantMessage(content: [], api: model.api, provider: model.provider,
                        model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .error, errorMessage: error.localizedDescription)
                    let stream = AssistantMessageEventStream()
                    stream.push(.error(reason: .error, error: failed))
                    stream.end(failed)
                    return stream
                }
            }, models: [HookProviderModel(id: "chat")]), sourceId: provider)
    }

    func model() throws -> Model { try #require(registry.find(provider, "chat")) }

    func session(hookRunner: HookRunner? = nil) throws -> AgentSession {
        let agent = Agent(AgentOptions(initialState: AgentState(model: try model()),
            sessionId: sessionManager.getSessionId(),
            getModelAuth: { model in
                await resolveCLIModelAuth(registry: registry, model: model,
                    sessionId: sessionManager.getSessionId(), hookRunner: hookRunner)
            }))
        agentBox.withLock { $0 = agent }
        let warmer = CacheWarmer(stream: makeCLICacheReplay(registry: registry, policy: policy,
            hookRunner: hookRunner), sessionManager: sessionManager,
            getMode: { settings.getCacheWarmingMode() })
        agent.streamFn = makeCLIAgentStream(registry: registry, policy: policy,
            sessionManager: sessionManager, agentBox: agentBox, cacheWarmer: warmer)
        return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: sessionManager,
            settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path,
                agentDir: directory.path, settingsManager: settings, noExtensions: true, offline: true)),
            hookRunner: hookRunner, modelRegistry: registry, cacheWarmer: warmer,
            clientIdentityProvider: { policy.resolve(registry) }))
    }

    func close() {
        registry.unregisterProviders(sourceId: provider)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("T1 CLI client identity", .serialized)
struct T1ClientIdentityTests {
    @Test func registryCallsAndAgentLoopReadTheCurrentPolicy() async throws {
        let fixture = try T1IdentityFixture()
        defer { fixture.close() }
        let model = try fixture.model()
        _ = await fixture.registry.streamSimple(model: model, context: Context(messages: [])).result()
        let session = try fixture.session()
        defer { session.dispose() }
        try await session.prompt("first")
        fixture.settings.setInstallTelemetryEnabled(true)
        try await session.prompt("second")
        fixture.settings.setInstallTelemetryEnabled(false)
        try await session.prompt("third")
        let identities = fixture.calls.withLock { $0.map(\.identity) }
        #expect(identities.count == 4)
        let disabled = ClientIdentity(userAgent: .detailed, attribution: .disabled, version: VERSION)
        #expect(identities[0] == disabled)
        #expect(identities[1] == disabled)
        #expect(identities[2] == getCodingAgentClientIdentity(SettingsManager.inMemory()))
        #expect(identities[3] == disabled)
        let wire = fixture.requests.withLock { $0 }
        #expect(wire.count == 4)
        let enabledIdentity = getCodingAgentClientIdentity(SettingsManager.inMemory())
        #expect(wire[2].value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: enabledIdentity))
        #expect(wire[2].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("pi/1.4.0 (") == true)
        #expect(wire[2].value(forHTTPHeaderField: "User-Agent")?.contains("; swift;") == true)
        if enabledIdentity.attribution == .value(PI_ATTRIBUTION) {
            #expect(wire[2].value(forHTTPHeaderField: "HTTP-Referer") == "https://pi.dev")
            #expect(wire[2].value(forHTTPHeaderField: "X-OpenRouter-Title") == "pi")
            #expect(wire[2].value(forHTTPHeaderField: "X-OpenRouter-Categories") == "cli-agent")
        }
        for request in [wire[0], wire[1], wire[3]] {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: disabled))
            #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == nil)
            #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Categories") == nil)
        }
    }

    @Test func registryAndRequestFieldsOverridePiDefaults() async throws {
        let host = LockedState(ClientIdentity(userAgent: .custom("Host/1"), version: "host-version"))
        let fixture = try T1IdentityFixture(registryIdentity: { host.withLock { $0 } })
        defer { fixture.close() }
        let session = try fixture.session()
        defer { session.dispose() }
        try await session.prompt("host")
        #expect(fixture.calls.withLock { $0.last?.identity } == ClientIdentity(userAgent: .custom("Host/1"),
            attribution: .disabled, version: "host-version"))
        host.withLock { $0.userAgent = .custom("Host/2") }
        session.agent.identity = ClientIdentity(userAgent: .custom("Request/3"))
        try await session.prompt("request")
        #expect(fixture.calls.withLock { $0.last?.identity } == ClientIdentity(userAgent: .custom("Request/3"),
            attribution: .disabled, version: "host-version"))
        #expect(fixture.requests.withLock { $0.last?.value(forHTTPHeaderField: "User-Agent") } == "Request/3")
        _ = await fixture.registry.streamSimple(model: try fixture.model(), context: Context(messages: []),
            options: SimpleStreamOptions(identity: ClientIdentity(version: "request-version"),
                headers: ["User-Agent": "Header/4", "X-OpenRouter-Title": "Header title"])).result()
        #expect(fixture.calls.withLock { $0.last?.identity?.version } == "request-version")
        #expect(fixture.requests.withLock { $0.last?.value(forHTTPHeaderField: "User-Agent") } == "Header/4")
        #expect(fixture.requests.withLock { $0.last?.value(forHTTPHeaderField: "X-OpenRouter-Title") } == "Header title")
    }

    @Test func trustSettingsChangeThePolicyWithoutReplacingTheRegistry() async throws {
        let fixture = try T1IdentityFixture()
        defer { fixture.close() }
        let trusted = SettingsManager.inMemory()
        fixture.policy.useSettings(trusted)
        _ = await fixture.registry.streamSimple(model: try fixture.model(), context: Context(messages: [])).result()
        #expect(fixture.calls.withLock { $0.last?.identity } == getCodingAgentClientIdentity(trusted))
        trusted.setInstallTelemetryEnabled(false)
        _ = await fixture.registry.streamSimple(model: try fixture.model(), context: Context(messages: [])).result()
        #expect(fixture.calls.withLock { $0.last?.identity?.attribution } == .disabled)
    }

    @Test func compactionAndBranchSummaryUseTheSessionPolicy() async throws {
        let fixture = try T1IdentityFixture()
        defer { fixture.close() }
        let session = try fixture.session()
        defer { session.dispose() }
        try await session.prompt("first")
        let firstLeaf = try #require(session.sessionManager.getLeafId())
        try await session.prompt("second")
        let branch = await session.navigateTree(firstLeaf, summarize: true)
        #expect(branch.cancelled == false)
        #expect(branch.summaryEntry != nil)
        try await session.prompt("third")
        _ = try await session.compact()
        let summaries = fixture.calls.withLock { $0.filter { $0.cacheRetention == CacheRetention.none } }
        #expect(summaries.count >= 2)
        for request in summaries {
            #expect(request.identity == ClientIdentity(userAgent: .detailed, attribution: .disabled, version: VERSION))
        }
    }

    @Test func cacheReplayReadsCurrentPolicyAndKeepsOpenCodeRouting() async throws {
        let fixture = try T1IdentityFixture(baseUrl: "https://opencode.ai/zen/v1")
        defer { fixture.close() }
        let session = try fixture.session()
        defer { session.dispose() }
        session.agent.identity = ClientIdentity(userAgent: .custom("Agent/old"), attribution: .value(PI_ATTRIBUTION))
        let replay = makeCLICacheReplay(registry: fixture.registry, policy: fixture.policy,
            hookRunner: nil)
        let options = SimpleStreamOptions(identity: ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION), version: "old"),
            apiKey: "test-key", sessionId: fixture.sessionManager.getSessionId())
        _ = try await replay(fixture.model(), Context(messages: []), options)
        let request = try #require(fixture.calls.withLock { $0.last })
        #expect(request.identity == ClientIdentity(userAgent: .detailed, attribution: .disabled, version: VERSION))
        #expect(providerHeaderValue(request.headers, name: "x-opencode-session") == fixture.sessionManager.getSessionId())
        let wire = try #require(fixture.requests.withLock { $0.last })
        #expect(wire.value(forHTTPHeaderField: "x-opencode-client") == nil)
        #expect(wire.value(forHTTPHeaderField: "x-opencode-session") == fixture.sessionManager.getSessionId())
        #expect(wire.value(forHTTPHeaderField: "User-Agent") == formatUserAgent(identity: request.identity))
    }

    @Test func finalHeaderHookRemovalsSurviveAgentSummaryAndReplayDispatch() async throws {
        let fixture = try T1IdentityFixture(baseUrl: "https://opencode.ai/zen/v1")
        defer { fixture.close() }
        let hookCalls = LockedState(0)
        let handler: HookHandler = { event, _ in
            let event = try #require(event as? BeforeProviderHeadersEvent)
            #expect(providerHeaderValue(event.headers, name: "x-opencode-session") != nil)
            hookCalls.withLock { $0 += 1 }
            return BeforeProviderHeadersEventResult(headers: [
                "uSeR-aGeNt": nil, "X-OpenCode-Session": nil, "X-OpenCode-Client": nil,
            ])
        }
        let runner = HookRunner([LoadedHook(path: "<t1-identity>", resolvedPath: "<t1-identity>",
            handlers: ["before_provider_headers": [handler]], isExtension: true)],
            fixture.directory.path, fixture.sessionManager, fixture.registry)
        let session = try fixture.session(hookRunner: runner)
        defer { session.dispose() }
        try await session.prompt("first")
        try await session.prompt("second")
        _ = try await session.compact()
        let replay = makeCLICacheReplay(registry: fixture.registry, policy: fixture.policy,
            hookRunner: runner)
        _ = try await replay(fixture.model(), Context(messages: []),
            SimpleStreamOptions(apiKey: "test-key", sessionId: fixture.sessionManager.getSessionId()))
        let calls = fixture.calls.withLock { $0 }
        let wire = fixture.requests.withLock { $0 }
        #expect(calls.count >= 4)
        #expect(hookCalls.withLock { $0 } == calls.count)
        #expect(wire.count == calls.count)
        for request in calls {
            #expect(providerHeadersContain(request.headers, name: "User-Agent"))
            #expect(providerHeaderValue(request.headers, name: "User-Agent") == nil)
            #expect(providerHeadersContain(request.headers, name: "x-opencode-session"))
            #expect(providerHeaderValue(request.headers, name: "x-opencode-session") == nil)
        }
        for request in wire {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
            #expect(request.value(forHTTPHeaderField: "x-opencode-session") == nil)
            #expect(request.value(forHTTPHeaderField: "x-opencode-client") == nil)
        }
    }

}
