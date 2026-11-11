import Foundation
import PiReviewExtension
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

struct CLISessionBundle: Sendable {
    let session: AgentSession
    let customToolsResult: CustomToolsLoadResult
    let mcpUi: InteractiveMcpUi?
    let resourceLoader: DefaultResourceLoader
    let diagnostics: [ResourceDiagnostic]
}

/// Build the first CLI session and every runtime replacement by the same path.
func buildCLISession(
    cwd: String,
    agentDir: String,
    sessionManager: SessionManager,
    parsed: Args,
    extensions: [String],
    settingsManager: SettingsManager,
    projectTrusted: Bool,
    authStorage: AuthStorage,
    modelRegistry: ModelRegistry,
    clientIdentityPolicy: CLIClientIdentityPolicy,
    eventBus: EventBus,
    scopedModels: [ScopedModel],
    initialModel: Model?,
    initialThinking requestedThinking: ThinkingLevel,
    sessionContext: SessionContext,
    shouldPrintMessages: Bool,
    isInteractive: Bool,
    resolvedOffline: Bool,
    isReplacement: Bool
) async throws -> CLISessionBundle {
    var runtimeDiagnostics: [ResourceDiagnostic] = []
    var initialThinking = requestedThinking
    var skillsSettings = settingsManager.getSkillsSettings()
    if parsed.noSkills == true {
        skillsSettings.enabled = false
    }

    let resourceLoader = DefaultResourceLoader(DefaultResourceLoaderOptions(
        cwd: cwd,
        agentDir: agentDir,
        settingsManager: settingsManager,
        additionalExtensionPaths: extensions,
        additionalSkillPaths: parsed.skills ?? [],
        additionalThemePaths: parsed.themes ?? [],
        noExtensions: parsed.noExtensions ?? false,
        builtinExtensions: builtInExtensions.map(\.name),
        disabledBuiltinExtensions: parsed.noMcp == true ? ["mcp"] : [],
        noSkills: parsed.noSkills ?? false,
        noPromptTemplates: parsed.noPromptTemplates ?? false,
        noContextFiles: parsed.noContextFiles ?? false,
        projectTrusted: projectTrusted,
        offline: resolvedOffline,
        systemPrompt: parsed.systemPrompt,
        appendSystemPrompt: parsed.appendSystemPrompt
    ))
    await resourceLoader.reload()
    time("resourceLoader.reload")
    runtimeDiagnostics += resourceLoader.getExtensions().diagnostics
    runtimeDiagnostics += resourceLoader.getSkills().diagnostics
    runtimeDiagnostics += resourceLoader.getPrompts().diagnostics
    runtimeDiagnostics += resourceLoader.getThemes().diagnostics

    let allBuiltInToolsMap = createAllTools(
        cwd: cwd,
        options: ToolsOptions(read: ReadToolOptions(
            autoResizeImages: settingsManager.getAutoResizeImages(),
            blockImages: settingsManager.getBlockImages()
        ))
    )
    let excludedTools = ToolNameMatcher(parsed.excludeTools ?? [])
    let disableCustomTools = parsed.noTools == true && parsed.tools == nil
    let baseHookPaths = parsed.noExtensions == true ? [] : settingsManager.getHooks()
    let hookPaths = baseHookPaths + (parsed.hooks ?? [])
    let hookLoadResult = parsed.noExtensions == true
        ? loadHooks(hookPaths, cwd: cwd, eventBus: eventBus)
        : discoverAndLoadHooks(hookPaths, cwd, agentDir, eventBus)
    time("discoverAndLoadHooks")
    runtimeDiagnostics += hookLoadResult.errors.map {
        ResourceDiagnostic(type: "error", message: "Failed to load hook \"\($0.path)\": \($0.error)")
    }

    let baseCustomToolPaths = parsed.noExtensions == true ? [] : settingsManager.getCustomTools()
    let customToolPaths = baseCustomToolPaths + (parsed.customTools ?? [])
    let builtInToolNames = allBuiltInToolsMap.keys.map { $0.rawValue }
    let customToolsResult = parsed.noExtensions == true
        ? loadCustomTools(customToolPaths, cwd, builtInToolNames, eventBus)
        : discoverAndLoadCustomTools(customToolPaths, cwd, builtInToolNames, agentDir, eventBus)
    time("discoverAndLoadCustomTools")
    runtimeDiagnostics += customToolsResult.errors.map {
        ResourceDiagnostic(type: "error", message: "Failed to load custom tool \"\($0.path)\": \($0.error)")
    }

    let extensionPaths = resourceLoader.getExtensions().paths.filter { !$0.hasPrefix(BUILTIN_PATH_PREFIX) }
    let discoverDefaultExtensions = parsed.noExtensions != true
    let extensionResult = await discoverAndLoadExtensions(
            extensionPaths,
            cwd,
            agentDir,
            eventBus,
            includeProjectExtensions: projectTrusted,
            discoverDefaults: discoverDefaultExtensions
        )
    time("discoverAndLoadExtensions")
    runtimeDiagnostics += extensionStartupDiagnostics(extensionResult)

    // Load built-ins after trust resolution, when project settings are available.
    let resolvedBuiltins = try await resolveBuiltinExtensionPaths(settingsManager: settingsManager,
        names: builtInExtensions.map(\.name), cwd: cwd, agentDir: agentDir, projectTrusted: projectTrusted)
    let disabledBuiltinPaths = Set(resolvedBuiltins.extensions.filter {
        $0.metadata.source == "builtin" && !$0.enabled
    }.map { "-" + $0.path })
    let explicitBuiltinPaths = Set(extensions.filter { $0.hasPrefix(BUILTIN_PATH_PREFIX) })
    let knownBuiltinPaths = Set(builtInExtensions.map { BUILTIN_PATH_PREFIX + $0.name })
    let mcpUi = await MainActor.run { isInteractive ? InteractiveMcpUi() : nil }
    let hostedBuiltins = startupBuiltinExtensions(
        agentDir: URL(fileURLWithPath: agentDir, isDirectory: true), mcpUi: mcpUi
    )
    let inlineExtensions = selectStartupInlineExtensions(
        hostedBuiltins + [PiReview.inlineExtension], disabledPaths: disabledBuiltinPaths,
        explicitPaths: explicitBuiltinPaths, noExtensions: parsed.noExtensions == true,
        noMcp: parsed.noMcp == true
    )
    let loadInlineExtensions: @Sendable () -> LoadExtensionsResult = {
        var hooks: [LoadedHook] = []
        var errors: [ExtensionLoadError] = explicitBuiltinPaths.subtracting(knownBuiltinPaths).sorted().map {
            .invalidExtension(path: $0, reason: "Unknown built-in extension: \($0)")
        }
        for inlineExtension in inlineExtensions {
            let result = ExtensionLoader.load(inlineExtension, cwd: cwd, eventBus: eventBus)
            if let hook = result.hook {
                hooks.append(hook)
            }
            if let error = result.error {
                errors.append(error)
            }
        }
        return LoadExtensionsResult(hooks: hooks, errors: errors)
    }
    let inlineExtensionResult = loadInlineExtensions()
    runtimeDiagnostics += extensionStartupDiagnostics(inlineExtensionResult, inline: true)

    let replacementResult = omitReplacedExtensions(extensionResult.hooks + inlineExtensionResult.hooks)
    runtimeDiagnostics += replacementResult.warnings
    let allHooks = hookLoadResult.hooks + replacementResult.hooks
    let hookRunner: HookRunner? = allHooks.isEmpty ? nil : HookRunner(allHooks, cwd, sessionManager, modelRegistry)

    let agentBox = LockedState<Agent?>(nil)
    let sessionBox = LockedState<AgentSession?>(nil)
    let sendMessageHandlerBox = LockedState<HookSendMessageHandler>({ _, _ in })

    let getCustomToolContext: @Sendable () -> CustomToolContext = {
        let agent = agentBox.withLock { $0 }
        let session = sessionBox.withLock { $0 }
        let handler = sendMessageHandlerBox.withLock { $0 }
        return CustomToolContext(
            sessionManager: session?.sessionManager ?? sessionManager,
            modelRegistry: session?.modelRegistry ?? modelRegistry,
            model: agent?.state.model,
            isIdle: { session?.isIdle ?? false },
            hasPendingMessages: { (session?.pendingMessageCount ?? 0) > 0 },
            abort: { Task { await session?.abort() } },
            events: eventBus,
            sendMessage: { message, options in handler(message, options) },
            clientIdentityProvider: {
                clientIdentityPolicy.resolve(session?.modelRegistry ?? modelRegistry)
            }
        )
    }

    let wrappedCustomTools = wrapCustomTools(customToolsResult.tools, getCustomToolContext)
        .filter { !disableCustomTools && !excludedTools.matches($0.name) }

    let extensionToolDefinitions = (hookRunner?.getExtensionTools() ?? []).map {
        LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: $0)
    }
    let wrappedExtensionTools = wrapCustomTools(extensionToolDefinitions, getCustomToolContext)
        .filter { !disableCustomTools && !excludedTools.matches($0.name) }

    var toolRegistry: [String: AgentTool] = [:]
    for (name, tool) in allBuiltInToolsMap {
        toolRegistry[name.rawValue] = tool
    }
    for tool in wrappedCustomTools + wrappedExtensionTools {
        toolRegistry[tool.name] = tool
    }
    let allToolDefinitions = Dictionary(
        (customToolsResult.tools + extensionToolDefinitions).map { ($0.tool.name, $0.tool) },
        uniquingKeysWith: { _, newer in newer }
    )
    let builtinNames = Set(ToolName.allCases.map(\.rawValue))
    let registryOrder = ToolName.allCases.map(\.rawValue) + (wrappedCustomTools + wrappedExtensionTools).map(\.name)
    let toolSelection = selectStartupTools(parsed, registeredTools: registryOrder.compactMap { name in
        guard toolRegistry[name] != nil else { return nil }
        let definition = allToolDefinitions[name]
        return InitialToolRegistration(name: name, isBuiltin: builtinNames.contains(name) && definition == nil,
            exposure: definition?.exposure ?? .direct, defaultActive: definition?.defaultActive ?? true)
    }, settingsManager: settingsManager)
    let registeredNames = Set(toolSelection.initial.registeredToolNames)
    toolRegistry = toolRegistry.filter { registeredNames.contains($0.key) }
    let toolDefinitions = allToolDefinitions.filter { registeredNames.contains($0.key) }
    let toolRegistryOrder = toolSelection.initial.registeredToolNames
    let allTools = toolSelection.initial.activeToolNames.compactMap { toolRegistry[$0] }
    let initialActiveToolNames = allTools.map(\.name)

    let loaderSystemPrompt = resourceLoader.getSystemPrompt()
    let loaderAppend = resourceLoader.getAppendSystemPrompt()
    let appendSystemPrompt = loaderAppend.isEmpty ? nil : loaderAppend.joined(separator: "\n\n")
    let makeSystemPromptOptions: @Sendable ([String]) -> BuildSystemPromptOptions = { toolNames in
        let validToolNames = toolNames.compactMap { ToolName(rawValue: $0) }
        return BuildSystemPromptOptions(
            customPrompt: loaderSystemPrompt,
            selectedTools: validToolNames,
            appendSystemPrompt: appendSystemPrompt,
            cwd: cwd,
            agentDir: agentDir,
            contextFiles: resourceLoader.getAgentsFiles(),
            skills: resourceLoader.getSkills().skills
        )
    }
    let rebuildSystemPrompt: @Sendable ([String]) -> String = { toolNames in
        do {
            return try buildSystemPrompt(makeSystemPromptOptions(toolNames))
        } catch {
            // Only custom section names are validated, and the CLI passes none.
            preconditionFailure("built-in system prompt sections are always valid: \(error)")
        }
    }

    let systemPrompt = rebuildSystemPrompt(initialActiveToolNames)
    time("buildSystemPrompt")

    if let cliThinking = parsed.thinking {
        initialThinking = cliThinking
    }

    let fallbackModel = initialModel ?? getModel(provider: .openai, modelId: "gpt-4o-mini")
    let blockImages = settingsManager.getBlockImages()
    let convertToLlmWithBlockImages: @Sendable ([AgentMessage]) -> [Message] = { messages in
        let converted = convertToLlm(messages)
        guard blockImages else { return converted }
        let filtered = filterImagesFromMessages(converted)
        if filtered.filtered > 0 {
            if let data = "[blockImages] Defense-in-depth: filtered \(filtered.filtered) image(s) at convertToLlm layer\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        return filtered.messages
    }
    let createdAgent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: systemPrompt,
            model: fallbackModel,
            thinkingLevel: initialThinking,
            tools: allTools
        ),
        convertToLlm: { messages in
            convertToLlmWithBlockImages(messages)
        },
        steeringMode: AgentSteeringMode(rawValue: settingsManager.getSteeringMode()),
        followUpMode: AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()),
        sessionId: sessionManager.getSessionId(),
        transport: settingsManager.getTransport(),
        thinkingBudgets: settingsManager.getThinkingBudgets(),
        getApiKey: { provider in
            return await authStorage.getApiKey(provider)
        },
        getModelAuth: { model in
            await resolveCLIModelAuth(registry: modelRegistry, model: model,
                sessionId: sessionManager.getSessionId(), hookRunner: hookRunner)
        },
        timeoutMs: settingsManager.getHttpIdleTimeoutMs(),
        websocketConnectTimeoutMs: settingsManager.getWebSocketConnectTimeoutMs(),
        beforeToolCall: hookRunner.map(makeHookRunnerBeforeToolCallHook),
        afterToolCall: hookRunner.map(makeHookRunnerAfterToolCallHook)
    ))
    agentBox.withLock { $0 = createdAgent }
    let cacheWarmer = CacheWarmer(
        stream: makeCLICacheReplay(registry: modelRegistry, policy: clientIdentityPolicy,
            hookRunner: hookRunner),
        sessionManager: sessionManager,
        getMode: { settingsManager.getCacheWarmingMode() },
        decide: { event in
            guard let hookRunner, hookRunner.hasHandlers(event.type) else { return event.action }
            return await hookRunner.emitCacheWarmingDecision(event)
        },
        onWarmed: { entry in sessionBox.withLock { $0 }?.emitCacheWarmed(entry) }
    )
    createdAgent.streamFn = makeCLIAgentStream(registry: modelRegistry, policy: clientIdentityPolicy,
        sessionManager: sessionManager, agentBox: agentBox, cacheWarmer: cacheWarmer)

    if initialThinking != .off && !createdAgent.state.model.reasoning {
        createdAgent.thinkingLevel = .off
    } else {
        let requested = PiSwiftAI.ThinkingLevel(rawValue: initialThinking.rawValue)
        let clamped = PiSwiftAI.clampThinkingLevel(
            model: createdAgent.state.model,
            requested: requested
        )
        createdAgent.thinkingLevel = clamped.flatMap { ThinkingLevel(rawValue: $0.rawValue) } ?? .off
    }

    if isReplacement || parsed.continue == true || parsed.resume == true {
        if !sessionContext.messages.isEmpty {
            createdAgent.messages = sessionContext.messages
        }
    }

    if !isReplacement && shouldPrintMessages && parsed.continue != true && parsed.resume != true {
        let contextFiles = resourceLoader.getAgentsFiles()
        if !contextFiles.isEmpty {
            print("Loaded project context from:")
            for file in contextFiles {
                print("  - \(file.path)")
            }
        }
    }

    let reloadExtensionsHook: @Sendable () async -> LoadExtensionsResult = {
        let fileExtensions = await discoverAndLoadExtensions(
            extensionPaths,
            cwd,
            agentDir,
            eventBus,
            includeProjectExtensions: projectTrusted,
            discoverDefaults: discoverDefaultExtensions
        )
        let inlineExtensions = loadInlineExtensions()
        let replaced = omitReplacedExtensions(fileExtensions.hooks + inlineExtensions.hooks)
        return LoadExtensionsResult(
            hooks: replaced.hooks,
            errors: fileExtensions.errors + inlineExtensions.errors,
            warnings: fileExtensions.warnings + inlineExtensions.warnings + replaced.warnings
        )
    }

    let fileCommands = loadSlashCommands(LoadSlashCommandsOptions(cwd: cwd, agentDir: agentDir))
    let promptTemplates = resourceLoader.getPrompts().prompts
    let createdSession = AgentSession(config: AgentSessionConfig(
        agent: createdAgent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: resourceLoader,
        projectTrusted: projectTrusted,
        systemPromptOptions: makeSystemPromptOptions(initialActiveToolNames),
        scopedModels: scopedModels,
        fileCommands: fileCommands,
        promptTemplates: promptTemplates,
        hookRunner: hookRunner,
        customTools: customToolsResult.tools,
        modelRegistry: modelRegistry,
        cacheWarmer: cacheWarmer,
        skillsSettings: skillsSettings,
        eventBus: eventBus,
        usesDefaultTools: toolSelection.usesDefaultTools,
        defaultToolModifiers: toolSelection.defaultToolModifiers,
        excludedToolNames: toolSelection.excludedToolNames,
        allowedToolNames: toolSelection.allowedToolNames,
        toolRegistry: toolRegistry,
        toolRegistryOrder: toolRegistryOrder,
        toolDefinitions: toolDefinitions,
        rebuildSystemPrompt: rebuildSystemPrompt,
        reloadExtensionsHook: reloadExtensionsHook,
        wrapExtensionTools: { tools in
            let defs = tools.map { LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: $0) }
            let wrapped = wrapCustomTools(defs, getCustomToolContext)
                .filter { !disableCustomTools && !excludedTools.matches($0.name) }
            return hookRunner.map { wrapToolsWithHooks(wrapped, $0) } ?? wrapped
        },
        clientIdentityProvider: { clientIdentityPolicy.resolve(modelRegistry) }
    ))

    sessionBox.withLock { $0 = createdSession }
    let sendMessageHandler: HookSendMessageHandler = { [weak createdSession] message, options in
        guard let session = createdSession else { return }
        Task { await session.sendHookMessage(message, options: options) }
    }
    customToolsResult.setSendMessageHandler(sendMessageHandler)
    sendMessageHandlerBox.withLock { $0 = sendMessageHandler }
    return CLISessionBundle(session: createdSession, customToolsResult: customToolsResult,
        mcpUi: mcpUi, resourceLoader: resourceLoader, diagnostics: runtimeDiagnostics)
}
