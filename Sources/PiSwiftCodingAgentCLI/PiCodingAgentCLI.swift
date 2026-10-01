import ArgumentParser
import Darwin
import Foundation
import PiReviewExtension
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

func selectStartupInlineExtensions(
    _ extensions: [InlineExtension],
    disabledPaths: Set<String>,
    explicitPaths: Set<String>,
    noExtensions: Bool
) -> [InlineExtension] {
    extensions.filter { item in
        if !item.builtin { return true }
        let path = BUILTIN_PATH_PREFIX + item.name
        return explicitPaths.contains(path) || (!noExtensions && !disabledPaths.contains("-" + path))
    }
}

func activatesStartupTool(_ definition: CustomTool?) -> Bool {
    guard let definition else { return true }
    let exposure = definition.exposure ?? .direct
    return (exposure == .direct || exposure == .modelOnly) && definition.defaultActive != false
}

@main
struct PiCodingAgentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pi-coding-agent",
        abstract: "AI coding assistant",
        discussion: Self.helpDiscussion(),
        version: VERSION,
        subcommands: [
            SessionSubcommand.self,
            PackageSubcommand.self,
            ConfigSubcommand.self,
            AuthSubcommand.self,
            UpdateSubcommand.self,
        ],
        defaultSubcommand: SessionSubcommand.self
    )

    static func runSession(_ cli: CLIOptions) async throws {
        markCodingAgentEnvironment()
        time("start")

        let migrationResult = runMigrations()
        let migratedProviders = migrationResult.migratedAuthProviders
        time("runMigrations")

        var parsed = cli.toArgs()
        time("parseArgs")
        let resolvedOffline = parsed.offline == true

        let cwd = FileManager.default.currentDirectoryPath
        let agentDir = getAgentDir()
        let startupSettingsManager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        let startupSettingsDiagnostics = collectSettingsDiagnostics(startupSettingsManager)
        applyStartupTerminalSettings(startupSettingsManager)
        let authStorage = AuthStorage.create(getAuthPath())
        let modelRegistry = ModelRegistry(authStorage, agentDir)
        let eventBus = createEventBus()
        time("discoverModels")

        if let listModelsOption = parsed.listModels {
            reportStartupDiagnostics(startupSettingsDiagnostics)
            switch listModelsOption {
            case .all:
                await listModels(modelRegistry, nil)
            case .search(let pattern):
                await listModels(modelRegistry, pattern)
            }
            return
        }

        if let exportPath = parsed.export {
            do {
                let outputPath = parsed.messages.first
                let result = try exportFromFile(exportPath, outputPath)
                print("Exported to: \(result)")
                return
            } catch {
                let message = error.localizedDescription
                fputs("Error: \(message)\n", stderr)
                Darwin.exit(1)
            }
        }

        if parsed.mode == .rpc, !parsed.fileArgs.isEmpty {
            fputs("Error: @file arguments are not supported in RPC mode\n", stderr)
            Darwin.exit(1)
        }

        let trustChoice = projectTrustChoice(
            approve: parsed.approve == true,
            noApprove: parsed.noApprove == true
        )
        let trustMode: HookMode = {
            if parsed.mode == .rpc { return .rpc }
            if parsed.mode == .json { return .json }
            if parsed.print == true || parsed.mode != nil { return .print }
            return .tui
        }()
        if trustMode == .tui {
            await runFirstTimeSetupIfNeeded(
                settingsManager: startupSettingsManager,
                isInteractive: true
            )
            time("firstTimeSetup")
        }
        let trustContext = await resolveProjectTrustForCLI(
            cwd: cwd,
            agentDir: agentDir,
            modelRegistry: modelRegistry,
            eventBus: eventBus,
            choice: trustChoice,
            persistChoice: trustChoice != nil,
            noExtensions: parsed.noExtensions == true,
            mode: trustMode,
            hasUI: trustMode == .tui
        )
        let trust = trustContext.trust
        let settingsManager = trustContext.settingsManager
        var runtimeDiagnostics: [ResourceDiagnostic] = []
        if trustMode == .tui, let useTheme = cli.useTheme {
            var overrides = Settings()
            overrides.theme = useTheme
            settingsManager.applyOverrides(overrides)
        }
        applyStartupTerminalSettings(settingsManager)
        time("SettingsManager.create")
        let themeName = resolveThemeSetting(settingsManager.getTheme(), appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? "system"
        markTerminalColorsPending()
        initTheme(themeName, enableWatcher: parsed.print != true && parsed.mode == nil)
        time("initTheme")

        // If stdin is a pipe, read all of it and prepend to the initial message
        if parsed.mode != .rpc, isatty(STDIN_FILENO) == 0 {
            var stdinContent = ""
            while let line = readLine(strippingNewline: false) {
                stdinContent += line
            }
            if !stdinContent.isEmpty {
                if parsed.messages.isEmpty {
                    parsed.messages.append(stdinContent)
                } else {
                    parsed.messages[0] = stdinContent + parsed.messages[0]
                }
            }
        }

        var resumeSession: String? = nil
        if parsed.resume == true {
            _ = KeybindingsManager.create()
            let sessionDir = parsed.sessionDir
                ?? getSessionDirEnvironmentOverride()
                ?? settingsManager.getSessionDir()
            let cwdValue = cwd
            resumeSession = await selectSession(
                settingsManager: settingsManager,
                projectTrusted: trust.trusted,
                currentSessionsLoader: { onPartial in
                    try await SessionManager.list(cwdValue, sessionDir, onPartial: onPartial)
                },
                allSessionsLoader: { onPartial in
                    if let sessionDir, !sessionDir.isEmpty {
                        try await SessionManager.list(cwdValue, sessionDir, onPartial: onPartial)
                    } else {
                        try await SessionManager.listAll(onPartial: onPartial)
                    }
                }
            )
            if resumeSession == nil {
                print("No session selected")
                return
            }
        }

        // v0.63.0 / v0.68.1 / v0.79.4: CLI --session-dir takes precedence; otherwise use
        // PI_CODING_AGENT_SESSION_DIR, then settings.json sessionDir.
        var resolvedSessionDirArgs = parsed
        if resolvedSessionDirArgs.sessionDir == nil {
            if let envDir = getSessionDirEnvironmentOverride() {
                resolvedSessionDirArgs.sessionDir = envDir
            } else if let settingsDir = settingsManager.getSessionDir(), !settingsDir.isEmpty {
                resolvedSessionDirArgs.sessionDir = settingsDir
            }
        }
        let sessionManager = try createSessionManager(resolvedSessionDirArgs, cwd: cwd, resumeSession: resumeSession)
        if let name = cli.sessionName.flatMap(normalizeSessionName) {
            sessionManager.appendSessionInfo(name)
        }
        time("createSessionManager")

        var scopedModels: [ScopedModel] = []
        let modelPatterns = parsed.models ?? settingsManager.getEnabledModels()
        if let patterns = modelPatterns, !patterns.isEmpty {
            scopedModels = await resolveModelScope(patterns, modelRegistry)
            time("resolveModelScope")
        }

        let isInteractive = parsed.print != true && parsed.mode == nil
        let mode = parsed.mode ?? .text
        let shouldPrintMessages = isInteractive
        var nonInteractiveSignalSources: [DispatchSourceSignal] = []
        if !isInteractive {
            _ = takeOverStdoutForMachineReadableOutput()
            nonInteractiveSignalSources = registerNonInteractiveSignalHandlers()
        }
        defer {
            if !nonInteractiveSignalSources.isEmpty {
                unregisterNonInteractiveSignalHandlers(nonInteractiveSignalSources)
            }
        }
        let sessionContext = sessionManager.buildSessionContext()
        let hasExistingSession = !sessionContext.messages.isEmpty
        let defaultThinkingLevel = ThinkingLevel(rawValue: settingsManager.getDefaultThinkingLevel() ?? DEFAULT_THINKING_LEVEL.rawValue) ?? DEFAULT_THINKING_LEVEL
        let useScopedModels = !scopedModels.isEmpty && parsed.continue != true && parsed.resume != true

        if !scopedModels.isEmpty {
            scopedModels = scopedModels.map { scoped in
                let resolvedThinking = scoped.isThinkingExplicit ? (scoped.thinkingLevel ?? .off) : defaultThinkingLevel
                return ScopedModel(model: scoped.model, thinkingLevel: resolvedThinking, isThinkingExplicit: scoped.isThinkingExplicit)
            }
        }

        let initialSelection = await findInitialModelForSession(
            parsed,
            scopedModels,
            settingsManager,
            modelRegistry,
            sessionContext,
            shouldPrintMessages
        )
        let initialModel = initialSelection.model
        let initialMessageResult = try prepareInitialMessage(
            &parsed,
            autoResizeImages: settingsManager.getAutoResizeImages(),
            blockImages: settingsManager.getBlockImages(),
            resizeOptions: initialModel?.inputLimits?.images?.resize
        )
        time("prepareInitialMessage")
        var initialThinking = startupThinkingLevel(
            settingsManager: settingsManager,
            model: initialModel,
            restoredLevel: hasExistingSession ? sessionContext.thinkingLevel : nil,
            scopedModel: initialSelection.scopedModel,
            cliLevel: parsed.thinking ?? initialSelection.cliThinkingLevel
        )

        if !isInteractive && initialModel == nil {
            fputs("No models available.\n", stderr)
            fputs("Set an API key environment variable (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, etc.)\n", stderr)
            fputs("Or create \(getModelsPath())\n", stderr)
            Darwin.exit(1)
        }

        if let apiKey = parsed.apiKey {
            let apiKeyModel: Model? = {
                if parsed.model != nil {
                    return initialSelection.model
                }
                if useScopedModels, let scopedModel = initialSelection.scopedModel {
                    return scopedModel.model
                }
                return nil
            }()

            guard let apiKeyModel else {
                fputs("--api-key requires a model to be specified via --model, --provider/--model, or --models\n", stderr)
                Darwin.exit(1)
            }

            authStorage.setRuntimeApiKey(apiKeyModel.provider, apiKey)
        }

        if !isInteractive, let model = initialModel {
            let apiKey = await authStorage.getApiKey(model.provider)
            if apiKey == nil {
                fputs("No API key found for \(model.provider)\n", stderr)
                Darwin.exit(1)
            }
        }

        var skillsSettings = settingsManager.getSkillsSettings()
        if parsed.noSkills == true {
            skillsSettings.enabled = false
        }

        let resourceLoader = DefaultResourceLoader(DefaultResourceLoaderOptions(
            cwd: cwd,
            agentDir: getAgentDir(),
            settingsManager: settingsManager,
            additionalExtensionPaths: cli.extensions,
            additionalSkillPaths: parsed.skills ?? [],
            additionalThemePaths: parsed.themes ?? [],
            noExtensions: parsed.noExtensions ?? false,
            builtinExtensions: builtInExtensions.map(\.name),
            noSkills: parsed.noSkills ?? false,
            noPromptTemplates: parsed.noPromptTemplates ?? false,
            noContextFiles: parsed.noContextFiles ?? false,
            projectTrusted: trust.trusted,
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
        // v0.68.0 / v0.70.0: tool selection is layered:
        //   --no-tools         → disable everything (no built-ins, no extension/custom tools)
        //   --no-builtin-tools → keep extension/custom tools, disable only the default built-in set
        //   --tools <names>    → explicit allowlist (overrides above defaults)
        //   (default)          → enable read/bash/edit/write built-ins
        let excludedToolNames = Set(parsed.excludeTools ?? [])
        let disableCustomTools = parsed.noTools == true && parsed.tools == nil
        let filteredSelectedToolNames = startupToolNames(parsed, settingsManager: settingsManager)
        let baseHookPaths = parsed.noExtensions == true ? [] : settingsManager.getHooks()
        let hookPaths = baseHookPaths + (parsed.hooks ?? [])
        let hookLoadResult = parsed.noExtensions == true
            ? loadHooks(hookPaths, cwd: cwd, eventBus: eventBus)
            : discoverAndLoadHooks(hookPaths, cwd, getAgentDir(), eventBus)
        time("discoverAndLoadHooks")
        runtimeDiagnostics += hookLoadResult.errors.map {
            ResourceDiagnostic(type: "error", message: "Failed to load hook \"\($0.path)\": \($0.error)")
        }

        let baseCustomToolPaths = parsed.noExtensions == true ? [] : settingsManager.getCustomTools()
        let customToolPaths = baseCustomToolPaths + (parsed.customTools ?? [])
        let builtInToolNames = allBuiltInToolsMap.keys.map { $0.rawValue }
        let customToolsResult = parsed.noExtensions == true
            ? loadCustomTools(customToolPaths, cwd, builtInToolNames, eventBus)
            : discoverAndLoadCustomTools(customToolPaths, cwd, builtInToolNames, getAgentDir(), eventBus)
        time("discoverAndLoadCustomTools")
        runtimeDiagnostics += customToolsResult.errors.map {
            ResourceDiagnostic(type: "error", message: "Failed to load custom tool \"\($0.path)\": \($0.error)")
        }

        let extensionPaths = resourceLoader.getExtensions().paths.filter { !$0.hasPrefix(BUILTIN_PATH_PREFIX) }
        let discoverDefaultExtensions = parsed.noExtensions != true
        let extensionResult = await discoverAndLoadExtensions(
                extensionPaths,
                cwd,
                getAgentDir(),
                eventBus,
                includeProjectExtensions: trust.trusted,
                discoverDefaults: discoverDefaultExtensions
            )
        time("discoverAndLoadExtensions")
        runtimeDiagnostics += extensionStartupDiagnostics(extensionResult)

        // Load built-ins after trust resolution, when project settings are available.
        let resolvedBuiltins = try await resolveBuiltinExtensionPaths(settingsManager: settingsManager,
            names: builtInExtensions.map(\.name), cwd: cwd, agentDir: getAgentDir(), projectTrusted: trust.trusted)
        let disabledBuiltinPaths = Set(resolvedBuiltins.extensions.filter {
            $0.metadata.source == "builtin" && !$0.enabled
        }.map { "-" + $0.path })
        let explicitBuiltinPaths = Set(cli.extensions.filter { $0.hasPrefix(BUILTIN_PATH_PREFIX) })
        let knownBuiltinPaths = Set(builtInExtensions.map { BUILTIN_PATH_PREFIX + $0.name })
        let inlineExtensions = selectStartupInlineExtensions(
            builtInExtensions + [PiReview.inlineExtension], disabledPaths: disabledBuiltinPaths,
            explicitPaths: explicitBuiltinPaths, noExtensions: parsed.noExtensions == true
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
                sessionManager: sessionManager,
                modelRegistry: modelRegistry,
                model: agent?.state.model,
                isIdle: { !(session?.isStreaming ?? true) },
                hasPendingMessages: { (session?.pendingMessageCount ?? 0) > 0 },
                abort: { Task { await session?.abort() } },
                events: eventBus,
                sendMessage: { message, options in handler(message, options) }
            )
        }

        let wrappedCustomTools = wrapCustomTools(customToolsResult.tools, getCustomToolContext)
            .filter { !disableCustomTools && !excludedToolNames.contains($0.name) }

        let extensionToolDefinitions = (hookRunner?.getExtensionTools() ?? []).map {
            LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: $0)
        }
        let wrappedExtensionTools = wrapCustomTools(extensionToolDefinitions, getCustomToolContext)
            .filter { !disableCustomTools && !excludedToolNames.contains($0.name) }

        let selectedToolNameSet = Set(filteredSelectedToolNames.map { $0.rawValue })
        let customToolsByName = Dictionary(uniqueKeysWithValues: wrappedCustomTools.map { ($0.name, $0) })
        let selectedTools = filteredSelectedToolNames.compactMap { name in
            customToolsByName[name.rawValue] ?? allBuiltInToolsMap[name]
        }
        let extraCustomTools = wrappedCustomTools.filter { !selectedToolNameSet.contains($0.name) }

        var toolRegistry: [String: AgentTool] = [:]
        for (name, tool) in allBuiltInToolsMap {
            toolRegistry[name.rawValue] = tool
        }
        for tool in wrappedCustomTools + wrappedExtensionTools {
            toolRegistry[tool.name] = tool
        }
        for name in excludedToolNames {
            toolRegistry.removeValue(forKey: name)
        }

        let toolDefinitions = Dictionary(
            (customToolsResult.tools + extensionToolDefinitions).map { ($0.tool.name, $0.tool) },
            uniquingKeysWith: { _, newer in newer }
        ).filter { toolRegistry[$0.key] != nil }
        var seenRegistryNames: Set<String> = []
        let toolRegistryOrder = (ToolName.allCases.map(\.rawValue) +
            (wrappedCustomTools + wrappedExtensionTools).map(\.name))
            .filter { toolRegistry[$0] != nil && seenRegistryNames.insert($0).inserted }
        let allTools = (selectedTools + extraCustomTools + wrappedExtensionTools)
            .filter { activatesStartupTool(toolDefinitions[$0.name]) }
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
                agentDir: getAgentDir(),
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
                let auth = await modelRegistry.getApiKeyAndHeaders(model)
                return AgentModelAuth(apiKey: auth.apiKey, headers: auth.headers, baseUrl: auth.baseUrl)
            },
            timeoutMs: settingsManager.getHttpIdleTimeoutMs(),
            websocketConnectTimeoutMs: settingsManager.getWebSocketConnectTimeoutMs(),
            beforeToolCall: hookRunner.map(makeHookRunnerBeforeToolCallHook),
            afterToolCall: hookRunner.map(makeHookRunnerAfterToolCallHook)
        ))
        agentBox.withLock { $0 = createdAgent }

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

        if parsed.continue == true || parsed.resume == true {
            if !sessionContext.messages.isEmpty {
                createdAgent.messages = sessionContext.messages
            }
        }

        if shouldPrintMessages && parsed.continue != true && parsed.resume != true {
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
                getAgentDir(),
                eventBus,
                includeProjectExtensions: trust.trusted,
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

        let fileCommands = loadSlashCommands(LoadSlashCommandsOptions(cwd: cwd, agentDir: getAgentDir()))
        let promptTemplates = resourceLoader.getPrompts().prompts
        let createdSession = AgentSession(config: AgentSessionConfig(
            agent: createdAgent,
            sessionManager: sessionManager,
            settingsManager: settingsManager,
            resourceLoader: resourceLoader,
            projectTrusted: trust.trusted,
            systemPromptOptions: makeSystemPromptOptions(initialActiveToolNames),
            scopedModels: scopedModels,
            fileCommands: fileCommands,
            promptTemplates: promptTemplates,
            hookRunner: hookRunner,
            customTools: customToolsResult.tools,
            modelRegistry: modelRegistry,
            skillsSettings: skillsSettings,
            eventBus: eventBus,
            toolRegistry: toolRegistry,
            toolRegistryOrder: toolRegistryOrder,
            toolDefinitions: toolDefinitions,
            rebuildSystemPrompt: rebuildSystemPrompt,
            reloadExtensionsHook: reloadExtensionsHook,
            wrapExtensionTools: { tools in
                let defs = tools.map { LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: $0) }
                let wrapped = wrapCustomTools(defs, getCustomToolContext)
                    .filter { !disableCustomTools && !excludedToolNames.contains($0.name) }
                return hookRunner.map { wrapToolsWithHooks(wrapped, $0) } ?? wrapped
            }
        ))
        sessionBox.withLock { $0 = createdSession }
        let sendMessageHandler: HookSendMessageHandler = { [weak createdSession] message, options in
            guard let session = createdSession else { return }
            Task {
                await session.sendHookMessage(message, options: options)
            }
        }
        customToolsResult.setSendMessageHandler(sendMessageHandler)
        sendMessageHandlerBox.withLock { $0 = sendMessageHandler }

        runtimeDiagnostics += collectSettingsDiagnostics(settingsManager)
        let diagnosticDisposition = startupDiagnosticDisposition(
            startup: startupSettingsDiagnostics,
            runtime: runtimeDiagnostics,
            isInteractive: isInteractive
        )
        let startupDiagnostics = diagnosticDisposition.diagnostics
        if diagnosticDisposition.shouldPrint { reportStartupDiagnostics(startupDiagnostics) }
        if diagnosticDisposition.hasRuntimeErrors { throw ExitCode.failure }

        if mode == .rpc {
            await runRpcMode(createdSession)
            return
        }

        if isInteractive {
            let changelogMarkdown = getChangelogForDisplay(parsed, settingsManager)

            if !migratedProviders.isEmpty {
                let list = migratedProviders.sorted().joined(separator: ", ")
                print("Migrated auth providers: \(list)")
            }

            if !scopedModels.isEmpty {
                let modelList = scopedModels.map { scoped in
                    let thinking = scoped.isThinkingExplicit ? ":\((scoped.thinkingLevel ?? .off).rawValue)" : ""
                    return "\(scoped.model.id)\(thinking)"
                }.joined(separator: ", ")
                print("Model scope: \(modelList) (Ctrl+P to cycle)")
            }

            printTimings()
            let interactiveMode = await MainActor.run {
                InteractiveMode(
                    session: createdSession,
                    version: VERSION,
                    changelogMarkdown: changelogMarkdown,
                    scopedModels: scopedModels,
                    customTools: customToolsResult.tools,
                    setToolUIContext: customToolsResult.setUIContext,
                    setToolSendMessageHandler: customToolsResult.setSendMessageHandler,
                    fdPath: nil,
                    verbose: parsed.verbose == true,
                    tuiMode: cli.parsedTuiModeOverride,
                    startupDiagnostics: startupDiagnostics,
                    initialThemeSetting: cli.useTheme
                )
            }
            await interactiveMode.start(
                initialMessages: parsed.messages,
                initialMessage: initialMessageResult.message,
                initialImages: initialMessageResult.images
            )
        } else {
            try await runPrintMode(
                createdSession,
                mode,
                parsed.messages,
                initialMessageResult.message,
                initialMessageResult.images
            )
        }
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let modeError = Self.modeArgumentError(arguments) {
            fputs("Error: \(modeError)\n", stderr)
            Darwin.exit(1)
        }
        let processed = Self.preprocessArguments(arguments)
        await self.main(processed)
    }

    static func modeArgumentError(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if argument == "--mode" {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") else {
                    return "--mode requires text, json, or rpc"
                }
                let value = arguments[index + 1]
                if Mode(rawValue: value) == nil {
                    return "Invalid mode \"\(value)\". Valid values: text, json, rpc"
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--mode=") {
                let value = String(argument.dropFirst("--mode=".count))
                if value.isEmpty { return "--mode requires text, json, or rpc" }
                if Mode(rawValue: value) == nil {
                    return "Invalid mode \"\(value)\". Valid values: text, json, rpc"
                }
            }
            index += 1
        }
        return nil
    }

    private static func helpDiscussion() -> String {
        return """
Usage: \(APP_NAME) [options] [--] [@files...] [messages...]

Options:
  -e, --extension <path>     Load an extension file or builtin:<name>
  -ne, --no-extensions       Disable extension discovery and built-in extensions
  --use-theme <name[/name]>  Set the initial interactive theme for this run
  --                        End option parsing; treat remaining arguments as messages/files

Examples:
  # Prompt beginning with a dash
  \(APP_NAME) -p -- "- Summarize these points"

  # Interactive mode
  \(APP_NAME)

  # Interactive mode with initial prompt
  \(APP_NAME) "List all .ts files in src/"

  # Include files in initial message
  \(APP_NAME) @prompt.md @image.png "What color is the sky?"

  # Non-interactive mode (process and exit)
  \(APP_NAME) -p "List all .ts files in src/"

  # Continue previous session
  \(APP_NAME) --continue "What did we discuss?"

  # Use different model
  \(APP_NAME) --provider openai --model gpt-4o-mini "Help me refactor this code"

  # Limit model cycling to specific models
  \(APP_NAME) --models claude-sonnet,claude-haiku,gpt-4o

  # Limit to a specific provider with glob pattern
  \(APP_NAME) --models "github-copilot/*"

  # Cycle models with fixed thinking levels
  \(APP_NAME) --models sonnet:high,haiku:low

  # Start with a specific thinking level
  \(APP_NAME) --thinking high "Solve this complex problem"

  # Read-only mode (no file modifications possible)
  \(APP_NAME) --tools read,grep,find,ls -p "Review the code in src/"

  # Export a session file to HTML
  \(APP_NAME) --export ~/\(CONFIG_DIR_NAME)/agent/sessions/--path--/session.jsonl
  \(APP_NAME) --export session.jsonl output.html

  # Configure resources (extensions, skills, prompts, themes)
  \(APP_NAME) config
  \(APP_NAME) config -l  # start in project-local scope

  # Manage MCP servers
  \(APP_NAME) mcp <command>

  # Manage packages (npm/git)
  \(APP_NAME) package install <source>
  \(APP_NAME) package remove <source>
  \(APP_NAME) package update [source]
  \(APP_NAME) package list

  # Check or export credentials
  \(APP_NAME) auth check --provider openai
  \(APP_NAME) auth print-api-key --provider openai
  \(APP_NAME) auth print-bearer-token --provider openai-codex

  # Refresh model catalogs
  \(APP_NAME) update --models

Environment Variables:
  ANTHROPIC_API_KEY       - Anthropic Claude API key
  ANTHROPIC_OAUTH_TOKEN   - Anthropic OAuth token (alternative to API key)
  OPENAI_API_KEY          - OpenAI GPT API key
  GEMINI_API_KEY          - Google Gemini API key
  GROQ_API_KEY            - Groq API key
  CEREBRAS_API_KEY        - Cerebras API key
  XAI_API_KEY             - xAI Grok API key
  OPENROUTER_API_KEY      - OpenRouter API key
  ZAI_API_KEY             - ZAI API key
  DEEPSEEK_API_KEY        - DeepSeek API key
  FIREWORKS_API_KEY       - Fireworks AI API key
  \(ENV_AGENT_DIR) - Session storage directory (default: ~/\(CONFIG_DIR_NAME)/agent)
  \(ENV_CODING_AGENT_SESSION_DIR) - Override session file directory

Built-in Tool Names:
  read  - Read file contents
  bash  - Execute bash commands
  edit  - Edit files with find/replace
  write - Write files (creates/overwrites)
  grep  - Search file contents (read-only, off by default)
  find  - Find files by glob pattern (read-only, off by default)
  ls    - List directory contents (read-only, off by default)
"""
    }

    static func preprocessArguments(_ args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                result.append(contentsOf: args[i...])
                break
            }
            if arg == "-ne" {
                result.append("--no-extensions")
                i += 1
                continue
            }
            if arg == "-ns" {
                result.append("--no-skills")
                i += 1
                continue
            }
            if arg == "-np" {
                result.append("--no-prompt-templates")
                i += 1
                continue
            }
            if arg == "-xt" {
                result.append("--exclude-tools")
                i += 1
                continue
            }
            if arg == "--list-models" {
                result.append(arg)
                if i + 1 < args.count {
                    let next = args[i + 1]
                    if !next.hasPrefix("-") && !next.hasPrefix("@") {
                        result.append("--list-models-search")
                        result.append(next)
                        i += 2
                        continue
                    }
                }
                i += 1
                continue
            }
            if arg.hasPrefix("--list-models=") {
                let value = String(arg.dropFirst("--list-models=".count))
                result.append("--list-models")
                if !value.isEmpty {
                    result.append("--list-models-search")
                    result.append(value)
                }
                i += 1
                continue
            }
            result.append(arg)
            i += 1
        }
        return moveLeadingSubcommandToFront(result)
    }

    private static func moveLeadingSubcommandToFront(_ args: [String]) -> [String] {
        let valueOptions: Set<String> = [
            "--provider", "--model", "--api-key", "--system-prompt",
            "--append-system-prompt", "--mode", "--tui-mode", "--thinking", "--session",
            "--session-id", "--session-dir", "--models", "-m", "--tools",
            "--exclude-tools", "--hook", "--tool", "--export", "--skills",
            "--theme", "--use-theme", "--name", "--list-models-search",
        ]
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return args }
            if argument.hasPrefix("-") {
                if valueOptions.contains(argument), index + 1 < args.count {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            break
        }

        guard index < args.count,
              ["package", "config", "auth", "update"].contains(args[index]),
              index > 0 else {
            return args
        }
        var routed = args
        let subcommand = routed.remove(at: index)
        routed.insert(subcommand, at: 0)
        return routed
    }
}

func reportStartupDiagnostics(_ diagnostics: [ResourceDiagnostic]) {
    for diagnostic in diagnostics {
        let prefix = diagnostic.type == "error" ? "Error: " : diagnostic.type == "warning" ? "Warning: " : ""
        fputs(prefix + diagnostic.message + "\n", stderr)
    }
}

struct PreparedInitialMessage {
    var message: String?
    var images: [ImageContent]?
}

func prepareInitialMessage(
    _ parsed: inout Args,
    autoResizeImages: Bool,
    blockImages: Bool,
    resizeOptions: ModelImageResizeOptions?
) throws -> PreparedInitialMessage {
    guard !parsed.fileArgs.isEmpty else {
        return PreparedInitialMessage(message: nil, images: nil)
    }

    let processed = try processFileArguments(
        parsed.fileArgs,
        options: ProcessFileOptions(autoResizeImages: autoResizeImages, blockImages: blockImages, resizeOptions: resizeOptions)
    )
    let textContent = processed.textContent
    if parsed.messages.isEmpty {
        return PreparedInitialMessage(message: textContent, images: processed.imageAttachments.isEmpty ? nil : processed.imageAttachments)
    }

    let first = parsed.messages.removeFirst()
    return PreparedInitialMessage(
        message: textContent + first,
        images: processed.imageAttachments.isEmpty ? nil : processed.imageAttachments
    )
}

private func getChangelogForDisplay(_ parsed: Args, _ settingsManager: SettingsManager) -> String? {
    if parsed.continue == true || parsed.resume == true {
        return nil
    }

    let lastVersion = settingsManager.getLastChangelogVersion()
    let changelogPath = getChangelogPath()
    let entries = parseChangelog(changelogPath)

    if lastVersion == nil {
        settingsManager.setLastChangelogVersion(VERSION)
        return nil
    } else if let lastVersion {
        let newEntries = getNewEntries(entries, lastVersion: lastVersion)
        if !newEntries.isEmpty {
            settingsManager.setLastChangelogVersion(VERSION)
            return newEntries.map { $0.content }.joined(separator: "\n\n")
        }
    }

    return nil
}

func createSessionManager(_ parsed: Args, cwd: String, resumeSession: String?) throws -> SessionManager {
    if parsed.noSession == true {
        return SessionManager.inMemory(cwd)
    }
    if let resumeSession {
        return try SessionManager.openValidated(resumeSession, parsed.sessionDir)
    }
    if let session = parsed.session {
        return try SessionManager.openValidated(session, parsed.sessionDir)
    }
    if parsed.continue == true {
        return SessionManager.continueRecent(cwd, parsed.sessionDir)
    }
    if let sessionDir = parsed.sessionDir {
        return SessionManager.create(cwd, sessionDir, sessionId: parsed.sessionId)
    }
    return SessionManager.create(cwd, nil, sessionId: parsed.sessionId)
}

private struct InitialModelSelection {
    var model: Model?
    var scopedModel: ScopedModel?
    var cliThinkingLevel: ThinkingLevel?
}

private func findInitialModelForSession(
    _ parsed: Args,
    _ scopedModels: [ScopedModel],
    _ settingsManager: SettingsManager,
    _ modelRegistry: ModelRegistry,
    _ sessionContext: SessionContext,
    _ shouldPrintMessages: Bool
) async -> InitialModelSelection {
    let hasExistingSession = !sessionContext.messages.isEmpty
    let useScopedModels = !scopedModels.isEmpty && parsed.continue != true && parsed.resume != true
    var restoreWarning: String?

    if parsed.model != nil {
        let resolved = resolveCliModel(
            cliProvider: parsed.provider,
            cliModel: parsed.model,
            modelRegistry: modelRegistry
        )
        if let warning = resolved.warning {
            fputs("Warning: \(warning)\n", stderr)
        }
        if let error = resolved.error {
            fputs("\(error)\n", stderr)
            Darwin.exit(1)
        }
        if let model = resolved.model {
            if !(await modelRegistry.isAvailable(model)) {
                fputs("Model \(model.provider)/\(model.id) is not available for the configured account.\n", stderr)
                Darwin.exit(1)
            }
            return InitialModelSelection(model: model, scopedModel: nil, cliThinkingLevel: resolved.thinkingLevel)
        }
        let display = parsed.provider != nil ? "\(parsed.provider!)/\(parsed.model ?? "")" : (parsed.model ?? "")
        fputs("Model \(display) not found\n", stderr)
        Darwin.exit(1)
    }

    if useScopedModels {
        if let provider = settingsManager.getDefaultProvider(),
           let modelId = settingsManager.getDefaultModel(),
           let savedModel = modelRegistry.find(provider, modelId),
           await modelRegistry.isAvailable(savedModel),
           let savedInScope = scopedModels.first(where: { modelsAreEqual($0.model, savedModel) }) {
            return InitialModelSelection(model: savedInScope.model, scopedModel: savedInScope, cliThinkingLevel: nil)
        }
        return InitialModelSelection(model: scopedModels[0].model, scopedModel: scopedModels[0], cliThinkingLevel: nil)
    }

    if hasExistingSession, let modelInfo = sessionContext.model {
        let restored = modelRegistry.find(modelInfo.provider, modelInfo.modelId)
        var hasApiKey = false
        var isAvailable = false
        if let restored {
            hasApiKey = await modelRegistry.getApiKeyForProvider(restored.provider) != nil
            isAvailable = await modelRegistry.isAvailable(restored)
        }
        if let restored, hasApiKey, isAvailable {
            if shouldPrintMessages {
                print("Restored model: \(modelInfo.provider)/\(modelInfo.modelId)")
            }
            return InitialModelSelection(model: restored, scopedModel: nil, cliThinkingLevel: nil)
        }

        let reason = restored == nil ? "model no longer exists" : (hasApiKey ? "model is not available for this account" : "no API key available")
        restoreWarning = "Could not restore model \(modelInfo.provider)/\(modelInfo.modelId) (\(reason))."
        if shouldPrintMessages {
            print("Warning: \(restoreWarning!)")
        }
    }

    if let provider = settingsManager.getDefaultProvider(),
       let modelId = settingsManager.getDefaultModel(),
       let model = modelRegistry.find(provider, modelId),
       await modelRegistry.isAvailable(model) {
        return InitialModelSelection(model: model, scopedModel: nil, cliThinkingLevel: nil)
    }

    let available = await modelRegistry.getAvailable()
    if let preferred = await selectDefaultModel(available: available, registry: modelRegistry) {
        if restoreWarning != nil && shouldPrintMessages {
            print("Falling back to: \(preferred.provider)/\(preferred.id)")
        }
        return InitialModelSelection(model: preferred, scopedModel: nil, cliThinkingLevel: nil)
    }
    if let fallback = available.first {
        if restoreWarning != nil && shouldPrintMessages {
            print("Falling back to: \(fallback.provider)/\(fallback.id)")
        }
        return InitialModelSelection(model: fallback, scopedModel: nil, cliThinkingLevel: nil)
    }
    if restoreWarning != nil, shouldPrintMessages {
        print("No fallback model available.")
    }
    return InitialModelSelection(model: nil, scopedModel: nil, cliThinkingLevel: nil)
}

private func runSimpleInteractiveLoop(
    _ session: AgentSession,
    initialMessages: [String],
    initialMessage: String?,
    initialImages: [ImageContent]?
) async throws {
    if let initialMessage {
        try await session.prompt(initialMessage, options: PromptOptions(expandSlashCommands: nil, images: initialImages))
        printAssistantOutput(session)
    }
    for message in initialMessages {
        try await session.prompt(message)
        printAssistantOutput(session)
    }

    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continue
        }
        try await session.prompt(line)
        printAssistantOutput(session)
    }
}

private func printAssistantOutput(_ session: AgentSession) {
    guard let last = session.agent.state.messages.last else { return }
    if case .assistant(let assistant) = last {
        if assistant.stopReason == .error || assistant.stopReason == .aborted {
            let message = assistant.errorMessage ?? "Request \(assistant.stopReason.rawValue)"
            fputs("\(message)\n", stderr)
            return
        }
        for block in assistant.content {
            if case .text(let text) = block {
                print(text.text)
            }
        }
    }
}
