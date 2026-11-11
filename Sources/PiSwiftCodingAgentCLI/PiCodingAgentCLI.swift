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
    noExtensions: Bool,
    noMcp: Bool = false
) -> [InlineExtension] {
    extensions.filter { item in
        if !item.builtin { return true }
        if noMcp && item.name == "mcp" { return false }
        let path = BUILTIN_PATH_PREFIX + item.name
        return explicitPaths.contains(path) || (!noExtensions && !disabledPaths.contains("-" + path))
    }
}

func activatesStartupTool(_ definition: CustomTool?) -> Bool {
    guard let definition else { return true }
    let exposure = definition.exposure ?? .direct
    return (exposure == .direct || exposure == .modelOnly) && definition.defaultActive != false
}

enum AppMode: Sendable, Equatable {
    case interactive, print, rpc, json

    var hookMode: HookMode {
        switch self {
        case .interactive: .tui
        case .print: .print
        case .rpc: .rpc
        case .json: .json
        }
    }
}

/// Descriptor state is supplied by the caller so tests do not need a real terminal.
func resolveAppMode(_ parsed: Args, stdinIsTTY: Bool, stdoutIsTTY: Bool) -> AppMode {
    if parsed.mode == .rpc { return .rpc }
    if parsed.mode == .json { return .json }
    if parsed.print == true || !stdinIsTTY || !stdoutIsTTY { return .print }
    return .interactive
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
            McpSubcommand.self,
            UpdateSubcommand.self,
            DurableSubcommand.self,
        ],
        defaultSubcommand: SessionSubcommand.self
    )

    static func runSession(_ cli: CLIOptions) async throws {
        markCodingAgentEnvironment()
        time("start")

        guard let cwdPointer = getcwd(nil, 0) else {
            let code = errno
            if code == ENOENT {
                fputs("Error: The current working directory no longer exists. Change to an existing directory and try again.\n", stderr)
                Darwin.exit(1)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let cwd = String(cString: cwdPointer)
        free(cwdPointer)

        let migrationResult = runMigrations()
        let migratedProviders = migrationResult.migratedAuthProviders
        time("runMigrations")

        var parsed = cli.toArgs()
        time("parseArgs")
        let resolvedOffline = parsed.offline == true
        let stdinIsTTY = isatty(STDIN_FILENO) == 1
        let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
        let appMode = resolveAppMode(parsed, stdinIsTTY: stdinIsTTY, stdoutIsTTY: stdoutIsTTY)
        let isInteractive = appMode == .interactive

        let agentDir = getAgentDir()
        let startupSettingsManager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
        let startupSettingsDiagnostics = collectSettingsDiagnostics(startupSettingsManager)
        applyStartupTerminalSettings(startupSettingsManager)
        let authStorage = AuthStorage.create(getAuthPath())
        let clientIdentityPolicy = CLIClientIdentityPolicy(startupSettingsManager)
        let modelRegistry = ModelRegistry(authStorage, agentDir, clientIdentityProvider: {
            clientIdentityPolicy.identity()
        })
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

        if appMode == .rpc, !parsed.fileArgs.isEmpty {
            fputs("Error: @file arguments are not supported in RPC mode\n", stderr)
            Darwin.exit(1)
        }

        let trustChoice = projectTrustChoice(
            approve: parsed.approve == true,
            noApprove: parsed.noApprove == true
        )
        let trustMode = appMode.hookMode
        if isInteractive {
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
            hasUI: isInteractive
        )
        let trust = trustContext.trust
        let settingsManager = trustContext.settingsManager
        clientIdentityPolicy.useSettings(settingsManager)
        var runtimeDiagnostics: [ResourceDiagnostic] = []
        if isInteractive, let useTheme = cli.useTheme {
            var overrides = Settings()
            overrides.theme = useTheme
            settingsManager.applyOverrides(overrides)
        }
        applyStartupTerminalSettings(settingsManager)
        time("SettingsManager.create")
        let themeName = resolveThemeSetting(settingsManager.getTheme(), appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? "system"
        markTerminalColorsPending()
        initTheme(themeName, enableWatcher: isInteractive)
        time("initTheme")

        // If stdin is a pipe, read all of it and prepend to the initial message
        if appMode != .rpc, !stdinIsTTY {
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
        var selectedSessionManager = try createSessionManager(resolvedSessionDirArgs, cwd: cwd, resumeSession: resumeSession)
        if let issue = getMissingSessionCwdIssue(selectedSessionManager, fallbackCwd: cwd),
           issue.sessionFile != nil {
            if isInteractive {
                let choice = await selectMissingSessionCwd(issue, settingsManager: startupSettingsManager)
                guard let opened = try openMissingSessionCwdChoice(choice, issue: issue,
                    sessionDir: resolvedSessionDirArgs.sessionDir) else { return }
                selectedSessionManager = opened
            } else {
                fputs(issue.errorMessage + "\n", stderr)
                Darwin.exit(1)
            }
        }
        let sessionManager = selectedSessionManager
        if let name = cli.sessionName.flatMap(normalizeSessionName) {
            sessionManager.appendSessionInfo(name)
        }
        time("createSessionManager")

        var scopedModels: [ScopedModel] = []
        let modelPatterns = parsed.models ?? settingsManager.getEnabledModels()
        if let patterns = modelPatterns, !patterns.isEmpty {
            let scope = await resolveModelScopeWithDiagnostics(patterns, modelRegistry)
            scopedModels = scope.scopedModels
            for warning in modelScopeWarningLines(scope.diagnostics) {
                fputs(warning + "\n", stderr)
            }
            time("resolveModelScope")
        }

        let shouldPrintMessages = isInteractive
        let sessionLifecycle = SessionRunLifecycle()
        var nonInteractiveSignalSources: [DispatchSourceSignal] = []
        if !isInteractive {
            _ = takeOverStdoutForMachineReadableOutput()
            nonInteractiveSignalSources = registerNonInteractiveSignalHandlers {
                await sessionLifecycle.shutdownAndDispose()
            }
        }
        defer {
            if !isInteractive {
                fflush(stdout)
                restoreStdoutAfterMachineReadableOutput()
            }
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

        var startupBundle: CLISessionBundle? = try await buildCLISession(
            cwd: cwd, agentDir: agentDir, sessionManager: sessionManager, parsed: parsed,
            extensions: cli.extensions, settingsManager: settingsManager,
            projectTrusted: trust.trusted, authStorage: authStorage, modelRegistry: modelRegistry,
            clientIdentityPolicy: clientIdentityPolicy, eventBus: eventBus,
            scopedModels: scopedModels, initialModel: initialModel, initialThinking: initialThinking,
            sessionContext: sessionContext, shouldPrintMessages: shouldPrintMessages,
            isInteractive: isInteractive, resolvedOffline: resolvedOffline, isReplacement: false
        )
        let resourceLoader = startupBundle!.resourceLoader
        let customToolsResult = startupBundle!.customToolsResult
        let mcpUi = startupBundle!.mcpUi
        runtimeDiagnostics += startupBundle!.diagnostics
        sessionLifecycle.install(startupBundle!.session)
        defer { sessionLifecycle.disposeOnce() }
        let replacementArgs = parsed
        let replacementExtensions = cli.extensions
        let replacementTheme = cli.useTheme
        let bundleBox = LockedState<CLISessionBundle?>(startupBundle)
        let replacementTrustSelector = LockedState<ProjectTrustOptionSelector?>(nil)
        let rpcShutdownBridge = RpcShutdownBridge()
        let runtime = AgentSessionRuntime(agentDir: agentDir, factory: { args in
            let eventBus = createEventBus()
            let authStorage = AuthStorage.create(getAuthPath())
            let identitySettings = SettingsManager.create(args.cwd, args.agentDir, projectTrusted: false)
            let identityPolicy = CLIClientIdentityPolicy(identitySettings)
            let registry = ModelRegistry(authStorage, args.agentDir, clientIdentityProvider: {
                identityPolicy.identity()
            })
            let trustContext = await resolveProjectTrustForCLI(
                cwd: args.cwd, agentDir: args.agentDir, modelRegistry: registry, eventBus: eventBus,
                choice: trustChoice, persistChoice: trustChoice != nil,
                noExtensions: replacementArgs.noExtensions == true,
                mode: appMode.hookMode, hasUI: isInteractive,
                selectTrustOption: replacementTrustSelector.withLock { $0 }
            )
            let settings = trustContext.settingsManager
            identityPolicy.useSettings(settings)
            if isInteractive, let replacementTheme {
                var overrides = Settings()
                overrides.theme = replacementTheme
                settings.applyOverrides(overrides)
            }
            var replacementScopedModels: [ScopedModel] = []
            let patterns = replacementArgs.models ?? settings.getEnabledModels()
            if let patterns, !patterns.isEmpty {
                let scope = await resolveModelScopeWithDiagnostics(patterns, registry)
                replacementScopedModels = scope.scopedModels
            }
            let defaultThinking = ThinkingLevel(rawValue: settings.getDefaultThinkingLevel()
                ?? DEFAULT_THINKING_LEVEL.rawValue) ?? DEFAULT_THINKING_LEVEL
            replacementScopedModels = replacementScopedModels.map { scoped in
                let resolved = scoped.isThinkingExplicit ? (scoped.thinkingLevel ?? .off) : defaultThinking
                return ScopedModel(model: scoped.model, thinkingLevel: resolved,
                    isThinkingExplicit: scoped.isThinkingExplicit)
            }
            let context = args.sessionManager.buildSessionContext()
            let selection = await findInitialModelForSession(replacementArgs, replacementScopedModels,
                settings, registry, context, false)
            let thinking = startupThinkingLevel(settingsManager: settings, model: selection.model,
                restoredLevel: context.messages.isEmpty ? nil : context.thinkingLevel,
                scopedModel: selection.scopedModel,
                cliLevel: replacementArgs.thinking ?? selection.cliThinkingLevel)
            let bundle = try await buildCLISession(
                cwd: args.cwd, agentDir: args.agentDir, sessionManager: args.sessionManager,
                parsed: replacementArgs, extensions: replacementExtensions,
                settingsManager: settings, projectTrusted: trustContext.trust.trusted,
                authStorage: authStorage, modelRegistry: registry,
                clientIdentityPolicy: identityPolicy, eventBus: eventBus,
                scopedModels: replacementScopedModels, initialModel: selection.model,
                initialThinking: thinking, sessionContext: context, shouldPrintMessages: false,
                isInteractive: isInteractive, resolvedOffline: resolvedOffline, isReplacement: true
            )
            bundleBox.withLock { $0 = bundle }
            return bundle.session
        }, initialSession: startupBundle!.session)
        sessionLifecycle.installRuntime(runtime)

        runtimeDiagnostics += collectSettingsDiagnostics(settingsManager)
        let diagnosticDisposition = startupDiagnosticDisposition(
            startup: startupSettingsDiagnostics,
            runtime: runtimeDiagnostics,
            isInteractive: isInteractive,
            resources: resourceLoader.getExtensions().diagnostics + resourceLoader.getSkills().diagnostics
                + resourceLoader.getPrompts().diagnostics + resourceLoader.getThemes().diagnostics,
            resourcesShown: settingsManager.getQuietStartup().showsStartupDetails(verbose: parsed.verbose == true)
        )
        let startupDiagnostics = diagnosticDisposition.diagnostics
        if diagnosticDisposition.shouldPrint { reportStartupDiagnostics(startupDiagnostics) }
        if diagnosticDisposition.hasRuntimeErrors {
            await sessionLifecycle.shutdownAndDispose()
            throw ExitCode.failure
        }

        if appMode == .rpc {
            startupBundle = nil
            await runRpcMode(runtime.session!, runtime: runtime, shutdownBridge: rpcShutdownBridge)
            await sessionLifecycle.shutdownAndDispose()
            return
        }

        if isInteractive {
            let changelogMarkdown = getChangelogForDisplay(parsed, settingsManager)

            if !migratedProviders.isEmpty {
                let list = migratedProviders.sorted().joined(separator: ", ")
                print("Migrated auth providers: \(list)")
            }

            let startupMode = InteractiveTuiConfiguration(settingsManager: settingsManager,
                modeOverride: cli.parsedTuiModeOverride).mode
            if startupMode != .fullscreen, let modelScope = startupModelScopeMessage(
                scopedModels, quietStartup: settingsManager.getQuietStartup(), verbose: parsed.verbose == true
            ) {
                print(modelScope)
            }

            printTimings()
            let interactiveMode = await MainActor.run {
                InteractiveMode(
                    session: runtime.session!,
                    version: VERSION,
                    runtime: runtime,
                    changelogMarkdown: changelogMarkdown,
                    scopedModels: scopedModels,
                    customTools: customToolsResult.tools,
                    mcpUi: mcpUi,
                    setToolUIContext: customToolsResult.setUIContext,
                    setToolSendMessageHandler: customToolsResult.setSendMessageHandler,
                    replacementBindings: { replacement in
                        bundleBox.withLock { bundle in
                            guard let bundle, bundle.session === replacement else { return nil }
                            return InteractiveSessionBindings(customToolsResult: bundle.customToolsResult,
                                mcpUi: bundle.mcpUi)
                        }
                    },
                    fdPath: nil,
                    verbose: parsed.verbose == true,
                    tuiMode: cli.parsedTuiModeOverride,
                    startupDiagnostics: startupDiagnostics,
                    initialThemeSetting: cli.useTheme,
                    shutdownSession: {
                        await sessionLifecycle.shutdownAndDispose()
                    },
                    exitProcess: { status in
                        sessionLifecycle.disposeOnce()
                        Darwin.exit(status)
                    }
                )
            }
            replacementTrustSelector.withLock { selector in
                selector = { [weak interactiveMode] targetCwd, targetSettings in
                    await interactiveMode?.selectReplacementProjectTrust(
                        cwd: targetCwd, settingsManager: targetSettings)
                }
            }
            startupBundle = nil
            await interactiveMode.start(
                initialMessages: parsed.messages,
                initialMessage: initialMessageResult.message,
                initialImages: initialMessageResult.images
            )
        } else {
            do {
                startupBundle = nil
                let status = try await runPrintMode(
                    runtime.session!,
                    appMode == .json ? .json : .text,
                    parsed.messages,
                    initialMessageResult.message,
                    initialMessageResult.images
                )
                await sessionLifecycle.shutdownAndDispose()
                if status != 0 {
                    throw ExitCode(Int32(status))
                }
            } catch {
                await sessionLifecycle.shutdownAndDispose()
                throw error
            }
        }
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let routed = Self.moveLeadingSubcommandToFront(arguments)
        if routed.first == "mcp" {
            await runMcpCLI(Array(routed.dropFirst()))
            return
        }
        if let modeError = Self.modeArgumentError(arguments) {
            fputs("Error: \(modeError)\n", stderr)
            Darwin.exit(1)
        }
        if let toolsError = Self.toolsArgumentError(arguments) {
            fputs("Error: \(toolsError)\n", stderr)
            Darwin.exit(1)
        }
        let processed = Self.preprocessArguments(arguments)
        await self.main(processed)
    }

    // Read raw arguments so diagnostics keep the user's flag spelling.
    static func toolsArgumentError(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if flag == "--tools" || flag == "-t" {
                let value: String
                if let separator = argument.firstIndex(of: "=") {
                    value = String(argument[argument.index(after: separator)...])
                    index += 1
                } else {
                    guard index + 1 < arguments.count else { return nil }
                    value = arguments[index + 1]
                    index += 2
                }
                let entries = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if let problem = getToolListError(entries) { return "\(flag): \(problem)" }
                continue
            }
            index += valueOptions.contains(argument) && index + 1 < arguments.count ? 2 : 1
        }
        return nil
    }

    static func modeArgumentError(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if ["--tools", "-t", "--exclude-tools", "-xt"].contains(argument) {
                index += 2
                continue
            }
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
  --no-tools, -nt           Disable all tools by default (built-in and extension)
  --no-builtin-tools, -nbt   Disable built-in tools by default but keep extension/custom tools enabled
  --tools, -t <tools>       Comma-separated allowlist of tool names or patterns (*) to enable
                            Keeps MCP tools unless an entry starts with mcp__
                            Only +name/-name entries add to or remove from the defaults
  --exclude-tools, -xt <tools> Comma-separated denylist of tool names or patterns (*) to disable
                            Applies to all tools, MCP tools included
  -e, --extension <path>     Load an extension file or builtin:<name>
  -ne, --no-extensions       Disable extension discovery and built-in extensions
  --no-mcp                  Disable built-in MCP support: no servers connect and no MCP tools
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

  # Add codemode to the default tools
  \(APP_NAME) --tools +codemode

  # Codemode with only the tools of one MCP server
  \(APP_NAME) --tools read,bash,codemode,'mcp__radius__*'

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
        let routed = moveLeadingSubcommandToFront(args)
        if routed.first == "mcp" { return preprocessMcpArguments(routed) }
        var result: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                result.append(contentsOf: args[i...])
                break
            }
            if ["--tools", "-t", "--exclude-tools", "-xt"].contains(arg) {
                result.append(arg == "-t" ? "--tools" : (arg == "-xt" ? "--exclude-tools" : arg))
                if i + 1 < args.count {
                    result.append(args[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if arg == "-nt" || arg == "-nbt" {
                result.append(arg == "-nt" ? "--no-tools" : "--no-builtin-tools")
                i += 1
                continue
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

    private static let valueOptions: Set<String> = [
        "--provider", "--model", "--api-key", "--system-prompt",
        "--append-system-prompt", "--mode", "--tui-mode", "--thinking", "--session",
        "--session-id", "--session-dir", "--models", "-m", "--tools", "-t",
        "--exclude-tools", "-xt", "--hook", "--tool", "--export", "--skills",
        "--extension", "-e", "--skill", "--prompt-template",
        "--theme", "--use-theme", "--name", "-n", "--list-models-search",
    ]

    private static func moveLeadingSubcommandToFront(_ args: [String]) -> [String] {
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
              ["package", "config", "auth", "mcp", "update", "durable"].contains(args[index]),
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
        if lastVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) == nil {
            settingsManager.setLastChangelogVersion(VERSION)
            return nil
        }
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

func modelScopeWarningLines(_ diagnostics: [ModelScopeDiagnostic]) -> [String] {
    diagnostics.map { "Warning: \($0.message)" }
}

func resolveStartupCliModel(_ parsed: Args, _ registry: ModelRegistry) async -> ResolveCliModelResult {
    var resolved = resolveCliModel(
        cliProvider: parsed.provider,
        cliModel: parsed.model,
        cliThinking: parsed.thinking,
        inlineApiKey: parsed.apiKey != nil,
        modelRegistry: registry
    )
    if let model = resolved.model,
       !(await registry.isAvailable(model, inlineApiKey: parsed.apiKey != nil)) {
        resolved.error = "Model \(model.provider)/\(model.id) is not available for the configured account."
        resolved.model = nil
    }
    return resolved
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

    if let provider = parsed.provider, !provider.isEmpty, parsed.model?.isEmpty != false {
        fputs("Error: --provider requires --model (for example: --provider \(provider) --model <pattern>)\n", stderr)
        Darwin.exit(1)
    }

    if parsed.model != nil {
        let resolved = await resolveStartupCliModel(parsed, modelRegistry)
        if let warning = resolved.warning {
            fputs("Warning: \(warning)\n", stderr)
        }
        if let error = resolved.error {
            fputs("\(error)\n", stderr)
            Darwin.exit(1)
        }
        if let model = resolved.model {
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
