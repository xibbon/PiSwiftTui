import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Keep the current settings after the CLI completes its project trust checks.
final class CLIClientIdentityPolicy: Sendable {
    private let settings: LockedState<SettingsManager>

    init(_ settingsManager: SettingsManager) {
        settings = LockedState(settingsManager)
    }

    func useSettings(_ settingsManager: SettingsManager) {
        settings.withLock { $0 = settingsManager }
    }

    func identity() -> ClientIdentity {
        getCodingAgentClientIdentity(settings.withLock { $0 })
    }

    func resolve(_ registry: ModelRegistry, _ request: ClientIdentity? = nil) -> ClientIdentity? {
        mergeClientIdentity(mergeClientIdentity(identity(), registry.resolveClientIdentity()), request)
    }

    func requestOptions(
        _ options: SimpleStreamOptions,
        registry: ModelRegistry,
        agentIdentity: ClientIdentity?,
        isAgentLoop: Bool
    ) -> SimpleStreamOptions {
        var request = options
        let explicitIdentity: ClientIdentity?
        if isAgentLoop,
                  options.identity == mergeClientIdentity(ClientIdentity(attribution: .value(PI_ATTRIBUTION)), agentIdentity) {
            // The Agent loop adds pi attribution. It must not defeat telemetry opt-out.
            explicitIdentity = agentIdentity
        } else {
            explicitIdentity = options.identity
        }
        request.identity = resolve(registry, explicitIdentity)
        return request
    }
}

func makeCLICacheReplay(
    registry: ModelRegistry,
    policy: CLIClientIdentityPolicy,
    hookRunner: HookRunner?
) -> CacheWarmer.Stream {
    { model, context, options in
        let resolved = await registry.resolveModelRequest(model, signal: options.signal, env: options.env)
        guard options.signal?.isCancelled != true else { throw CancellationError() }
        guard resolved.auth.ok || options.apiKey != nil || options.headers?.isEmpty == false else {
            throw AgentSessionError.missingApiKey(provider: resolved.model.provider)
        }
        var request = options
        // Match SDK replay: use the current policy, without saved request or Agent identity.
        request.identity = policy.resolve(registry)
        request.apiKey = request.apiKey ?? resolved.auth.apiKey
        if let environment = resolved.auth.env {
            request.env = environment.merging(request.env ?? [:]) { _, requestValue in requestValue }
        }
        request.headers = mergeProviderHeaders(resolved.model.headers,
            mergeProviderHeaders(resolved.auth.headers, request.headers))
        request.headers = openCodeSessionHeaders(model: resolved.model, sessionId: request.sessionId, headers: request.headers)
        if let hookRunner, hookRunner.hasHandlers("before_provider_headers") {
            request.headers = await hookRunner.emitBeforeProviderHeaders(request.headers ?? [:])
        }
        return try await registry.streamSimplePrepared(model: resolved.model, context: context, options: request).result()
    }
}

func makeCLIAgentStream(
    registry: ModelRegistry,
    policy: CLIClientIdentityPolicy,
    sessionManager: SessionManager,
    agentBox: LockedState<Agent?>,
    cacheWarmer: CacheWarmer
) -> StreamFn {
    { model, context, options in
        let isAgentLoop = options.sessionId == sessionManager.getSessionId()
        let request = policy.requestOptions(options, registry: registry,
            agentIdentity: agentBox.withLock { $0?.identity }, isAgentLoop: isAgentLoop)
        if isAgentLoop {
            let originalMessages = agentBox.withLock { $0?.state.messages ?? [] }
                .map { encodeAgentMessageJSON($0).serialized() }
            await cacheWarmer.start(
                CacheWarmRequest(model: model, context: Context(messages: context.messages), options: request),
                isCurrent: {
                    guard let current = agentBox.withLock({ $0?.state }),
                          current.model.provider == model.provider,
                          current.model.id == model.id,
                          current.messages.count >= originalMessages.count else { return false }
                    return zip(originalMessages, current.messages).allSatisfy { expected, message in
                        expected == encodeAgentMessageJSON(message).serialized()
                    }
                })
        }
        // Agent auth and session summary preparation have already applied the final header hook.
        // The public prepared dispatch retains mixed-case nil header deletion markers.
        return try registry.streamSimplePrepared(model: model, context: Context(messages: context.messages), options: request)
    }
}

func resolveCLIModelAuth(
    registry: ModelRegistry,
    model: Model,
    sessionId: String,
    hookRunner: HookRunner?
) async -> AgentModelAuth {
    let resolved = await registry.resolveModelRequest(model)
    let auth = resolved.auth
    var headers = mergeProviderHeaders(resolved.model.headers, auth.headers)
    headers = openCodeSessionHeaders(model: resolved.model, sessionId: sessionId, headers: headers)
    if let hookRunner, hookRunner.hasHandlers("before_provider_headers") {
        headers = await hookRunner.emitBeforeProviderHeaders(headers ?? [:])
    }
    return AgentModelAuth(apiKey: auth.apiKey, headers: headers, baseUrl: auth.baseUrl,
        env: auth.env, error: auth.error)
}
