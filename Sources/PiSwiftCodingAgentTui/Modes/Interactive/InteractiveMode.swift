import Foundation
import Dispatch
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import Darwin
import PiSwiftCodingAgent

func visibleStartupExtensionPaths(_ paths: [String]) -> [String] {
    paths.filter { !$0.hasPrefix(BUILTIN_PATH_PREFIX) }
}

@MainActor
public protocol RenderRequesting: AnyObject {
    func requestRender()
}

@MainActor
private final class TuiRenderAdapter: RenderRequesting {
    private let tui: TUI

    init(_ tui: TUI) {
        self.tui = tui
    }

    func requestRender() {
        tui.requestRender()
    }
}

@MainActor
private final class TuiOverlayHandle: HookOverlayHandle {
    private let handle: OverlayHandle

    init(_ handle: OverlayHandle) {
        self.handle = handle
    }

    func hide() {
        handle.hide()
    }

    func setHidden(_ hidden: Bool) {
        handle.setHidden(hidden)
    }

    func isHidden() -> Bool {
        handle.isHidden()
    }
}

@MainActor
private final class NullRenderRequester: RenderRequesting {
    func requestRender() {}
}

@MainActor
private struct InteractiveHookUIContext: HookUIContext {
    private let selectHandler: (String, [String]) async -> String?
    private let confirmHandler: (String, String) async -> Bool
    private let inputHandler: (String, String?) async -> String?
    private let notifyHandler: (String, HookNotificationType?) -> Void
    private let setStatusHandler: (String, String?) -> Void
    private let setWorkingMessageHandler: (String?) -> Void
    private let setWorkingVisibleHandler: (Bool) -> Void
    private let setWorkingIndicatorHandler: (WorkingIndicatorOptions?) -> Void
    private let setHiddenThinkingLabelHandler: (String?) -> Void
    private let addAutocompleteProviderHandler: (@escaping HookAutocompleteProviderFactory) -> Void
    private let setWidgetHandler: (String, HookWidgetContent?) -> Void
    private let setFooterHandler: (HookFooterFactory?) -> Void
    private let setTitleHandler: (String) -> Void
    private let customHandler: (@escaping HookCustomFactory, HookCustomOptions?) async -> HookCustomResult?
    private let pasteToEditorHandler: (String) -> Void
    private let setEditorTextHandler: (String) -> Void
    private let getEditorTextHandler: () -> String
    private let editorHandler: (String, String?) async -> String?
    private let setEditorComponentHandler: (HookEditorComponentFactory?) -> Void
    private let getAllThemesHandler: () -> [HookThemeInfo]
    private let getThemeHandler: (String) -> Theme?
    private let setThemeHandler: (HookThemeInput) -> HookThemeResult
    private let getToolsExpandedHandler: () -> Bool
    private let setToolsExpandedHandler: (Bool) -> Void
    private let themeProvider: () -> Theme

    init(
        select: @escaping (String, [String]) async -> String?,
        confirm: @escaping (String, String) async -> Bool,
        input: @escaping (String, String?) async -> String?,
        notify: @escaping (String, HookNotificationType?) -> Void,
        setStatus: @escaping (String, String?) -> Void,
        setWorkingMessage: @escaping (String?) -> Void,
        setWorkingVisible: @escaping (Bool) -> Void,
        setWorkingIndicator: @escaping (WorkingIndicatorOptions?) -> Void,
        setHiddenThinkingLabel: @escaping (String?) -> Void,
        addAutocompleteProvider: @escaping (@escaping HookAutocompleteProviderFactory) -> Void,
        setWidget: @escaping (String, HookWidgetContent?) -> Void,
        setFooter: @escaping (HookFooterFactory?) -> Void,
        setTitle: @escaping (String) -> Void,
        custom: @escaping (@escaping HookCustomFactory, HookCustomOptions?) async -> HookCustomResult?,
        pasteToEditor: @escaping (String) -> Void,
        setEditorText: @escaping (String) -> Void,
        getEditorText: @escaping () -> String,
        editor: @escaping (String, String?) async -> String?,
        setEditorComponent: @escaping (HookEditorComponentFactory?) -> Void,
        getAllThemes: @escaping () -> [HookThemeInfo],
        getTheme: @escaping (String) -> Theme?,
        setTheme: @escaping (HookThemeInput) -> HookThemeResult,
        getToolsExpanded: @escaping () -> Bool,
        setToolsExpanded: @escaping (Bool) -> Void,
        themeProvider: @escaping () -> Theme
    ) {
        self.selectHandler = select
        self.confirmHandler = confirm
        self.inputHandler = input
        self.notifyHandler = notify
        self.setStatusHandler = setStatus
        self.setWorkingMessageHandler = setWorkingMessage
        self.setWorkingVisibleHandler = setWorkingVisible
        self.setWorkingIndicatorHandler = setWorkingIndicator
        self.setHiddenThinkingLabelHandler = setHiddenThinkingLabel
        self.addAutocompleteProviderHandler = addAutocompleteProvider
        self.setWidgetHandler = setWidget
        self.setFooterHandler = setFooter
        self.setTitleHandler = setTitle
        self.customHandler = custom
        self.pasteToEditorHandler = pasteToEditor
        self.setEditorTextHandler = setEditorText
        self.getEditorTextHandler = getEditorText
        self.editorHandler = editor
        self.setEditorComponentHandler = setEditorComponent
        self.getAllThemesHandler = getAllThemes
        self.getThemeHandler = getTheme
        self.setThemeHandler = setTheme
        self.getToolsExpandedHandler = getToolsExpanded
        self.setToolsExpandedHandler = setToolsExpanded
        self.themeProvider = themeProvider
    }

    func select(_ title: String, _ options: [String]) async -> String? {
        await selectHandler(title, options)
    }

    func confirm(_ title: String, _ message: String) async -> Bool {
        await confirmHandler(title, message)
    }

    func input(_ title: String, _ placeholder: String?) async -> String? {
        await inputHandler(title, placeholder)
    }

    func notify(_ message: String, _ type: HookNotificationType?) {
        notifyHandler(message, type)
    }

    func setStatus(_ key: String, _ text: String?) {
        setStatusHandler(key, text)
    }

    func setWorkingMessage(_ message: String?) {
        setWorkingMessageHandler(message)
    }

    func setWorkingVisible(_ visible: Bool) {
        setWorkingVisibleHandler(visible)
    }

    func setWorkingIndicator(_ options: WorkingIndicatorOptions?) {
        setWorkingIndicatorHandler(options)
    }

    func setHiddenThinkingLabel(_ label: String?) {
        setHiddenThinkingLabelHandler(label)
    }

    func addAutocompleteProvider(_ factory: @escaping HookAutocompleteProviderFactory) {
        addAutocompleteProviderHandler(factory)
    }

    func setWidget(_ key: String, _ content: HookWidgetContent?) {
        setWidgetHandler(key, content)
    }

    func setFooter(_ factory: HookFooterFactory?) {
        setFooterHandler(factory)
    }

    func setTitle(_ title: String) {
        setTitleHandler(title)
    }

    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? {
        await customHandler(factory, options)
    }

    func pasteToEditor(_ text: String) {
        pasteToEditorHandler(text)
    }

    func setEditorText(_ text: String) {
        setEditorTextHandler(text)
    }

    func getEditorText() -> String {
        getEditorTextHandler()
    }

    func editor(_ title: String, _ prefill: String?) async -> String? {
        await editorHandler(title, prefill)
    }

    func setEditorComponent(_ factory: HookEditorComponentFactory?) {
        setEditorComponentHandler(factory)
    }

    func getAllThemes() -> [HookThemeInfo] {
        getAllThemesHandler()
    }

    func getTheme(_ name: String) -> Theme? {
        getThemeHandler(name)
    }

    func setTheme(_ theme: HookThemeInput) -> HookThemeResult {
        setThemeHandler(theme)
    }

    func getToolsExpanded() -> Bool {
        getToolsExpandedHandler()
    }

    func setToolsExpanded(_ expanded: Bool) {
        // Upstream #7292: a no-op when the state already matches, so extensions calling
        // setToolsExpanded(false) at startup do not emit a redundant collapse notice or force a
        // full re-render of every transcript child.
        guard expanded != getToolsExpandedHandler() else { return }
        setToolsExpandedHandler(expanded)
    }

    var theme: Theme {
        themeProvider()
    }
}

@MainActor
public final class InteractiveMode {
    struct ResourceDisplayOptions: Sendable {
        var extensionPaths: [String]
        var force: Bool
    }

    private struct ScopeGroup: Sendable {
        var scope: String
        var paths: [String]
        var packages: [String: [String]]
    }

    public var chatContainer: Container
    public var ui: RenderRequesting
    public var lastStatusSpacer: Spacer?
    public var lastStatusText: ThemedText?
    private var lastStatusMessage = ""
    var builtInHeader: ExpandableText?
    private let startupHeaderContainer = Container()
    let loadedResourcesContainer = Container()

    private var session: AgentSession?
    var crashLog = CrashLog()
    private var tui: TUI?
    lazy var programStatus = ProgramStatusReporter(
        send: { [weak self] status in self?.tui?.setProgramStatus(status) },
        getSessionName: { [weak self] in self?.session?.sessionManager.getSessionName() }
    )
    // Swift also settles idle manual compaction. Keep its result until the next run.
    private var reportingManualCompaction = false
    private var altScreenRenderer: AltScreenRenderer?
    var clipboardCopy: (String) -> PiSwiftCodingAgent.ClipboardCopyResult = copyToClipboard
    var clipboardFiles: () throws -> [String]? = readClipboardFilePaths
    var clipboardImage: () -> ClipboardImageReadResult = readClipboardImagePngData
    var clipboardText: () -> ClipboardReadResult = readClipboardText
    var writeClipboardImage: (Data, URL) throws -> Void = { try $0.write(to: $1) }
    private var composition: InteractiveComposition?
    private(set) var tuiConfiguration: InteractiveTuiConfiguration
    private var tuiModeOverride: InteractiveTuiMode?
    private var version: String = VERSION
    private var changelogMarkdown: String?
    private var scopedModels: [ScopedModel] = []
    private var fdPath: String?
    private var verboseStartup = false
    private var pendingResourceDisplayOptions: ResourceDisplayOptions?

    private var pendingMessagesContainer: Container?
    private(set) var statusContainer: Container?
    private var widgetContainer: Container?
    private var defaultEditor: CustomEditor?
    private var editor: EditorComponentView?
    private var autocompleteProvider: CombinedAutocompleteProvider?
    /// v0.70.5: extension-registered wrapper factories. Each receives the current provider and
    /// returns a wrapped replacement. Stacks in registration order.
    private var autocompleteProviderWrappers: [@MainActor @Sendable (AutocompleteProvider) -> AutocompleteProvider] = []
    /// Final stacked provider applied to the editor (the base CombinedAutocompleteProvider
    /// possibly wrapped one or more times).
    private(set) var stackedAutocompleteProvider: AutocompleteProvider?
    var editorContainer: Container?
    private var footer: FooterComponent?
    private var footerContainer: Container?
    private var customFooter: Component?
    private var footerDataProvider: FooterDataProvider?
    private var footerBranchUnsubscribe: (() -> Void)?
    private var hookSelector: HookSelectorComponent?
    private var hookInput: HookInputComponent?
    private var hookEditor: HookEditorComponent?
    private var hookWidgets: [String: Component] = [:]
    private var hookWidgetOrder: [String] = []
    private var baseSlashCommands: [SlashCommand] = []
    private var skillCommands: [String: String] = [:]
    private var skills: [Skill] = []
    private var customTools: [String: LoadedCustomTool] = [:]
    private var hookShortcuts: [KeyId: HookShortcut] = [:]
    private var keybindings: KeybindingsManager = KeybindingsManager.inMemory()
    private var mcpUi: InteractiveMcpUi?
    private var selectorCancel: (() -> Void)?
    /// Startup catalog refresh; cancelled on shutdown so it cannot outlive the session.
    private var backgroundCatalogRefreshTask: Task<Void, Never>?
    private var setToolUIContext: (HookUIContext, Bool) -> Void = { _, _ in }
    private var setToolSendMessageHandler: (@Sendable (_ handler: @escaping HookSendMessageHandler) -> Void) = { _ in }

    private var isInitialized = false
    private(set) var loadingAnimation: WorkingStatusIndicator?
    private var transientStatusAnimation: WorkingStatusIndicator?
    private var transientStatusMessage: String?
    private var modelSelectionRevision = 0

    func recordUserModelSelection() { modelSelectionRevision += 1 }

    func canApplyPostLoginSelection(_ candidateSession: AgentSession, previousModel: Model, revision: Int) -> Bool {
        session === candidateSession && modelSelectionRevision == revision &&
            candidateSession.agent.state.model.provider == previousModel.provider &&
            candidateSession.agent.state.model.id == previousModel.id
    }
    private(set) var activeWorkingIndicatorEmbedded = false
    private var startupDiagnostics: [ResourceDiagnostic] = []
    private var startupToolStatuses: [ToolStatus] = []
    private var initialThemeSetting: String?
    private var injectedTerminal: Terminal?
    var terminalForNewTui: Terminal { injectedTerminal ?? ProcessTerminal() }
    private var themeController: InteractiveThemeController?
    private var lastSigintTime: TimeInterval = 0
    private var lastEscapeTime: TimeInterval = 0

    private var streamingComponent: AssistantMessageComponent?
    private var streamingMessage: AssistantMessage?
    private var pendingTools: [String: ToolExecutionComponent] = [:]
    private let bugReportHints = BugReportHintTracker()
    private var entriesRenderedByBoundaryCompaction: Set<String> = []
    private var toolOutputExpanded = false
    private(set) var hideThinkingBlock = false
    private let defaultWorkingMessage = "Working"
    private var workingMessage: String?
    private(set) var workingVisible = true
    private(set) var workingIndicatorOptions: WorkingIndicatorOptions?
    private(set) var hiddenThinkingLabel: String?

    private var isBashMode = false
    private var bashComponent: BashExecutionComponent?
    private var bashAbort: CancellationToken?
    private var pendingBashComponents: [BashExecutionComponent] = []
    private var pendingBashMessages: [BashExecutionMessage] = []

    private var pendingSteeringMessages: [String] = []
    private var pendingFollowUpMessages: [String] = []

    private static let maxWidgetLines = 10

    private var exitContinuation: CheckedContinuation<Void, Never>?
    private var unsubscribe: (() -> Void)?
    private var unsubscribeHookEvents: (@Sendable () -> Void)?
    private var hookEventContinuation: AsyncStream<any HookEvent>.Continuation?
    private var hookEventTask: Task<Void, Never>?
    private var sigcontSource: DispatchSourceSignal?
    private var isShuttingDown = false
    private var hasExitedForTerminalError = false
    /// The CLI exits the process. Tests can record the status instead.
    var exitProcess: @MainActor (Int32) -> Void = { Darwin.exit($0) }
    /// v0.70.5: signal sources for SIGHUP/SIGTERM that drive a clean shutdown so extensions
    /// receive `session_shutdown` and detached children get killed before the process exits.
    private var shutdownSignalSources: [DispatchSourceSignal] = []

    public init(
        chatContainer: Container = Container(),
        ui: RenderRequesting,
        tuiConfiguration: InteractiveTuiConfiguration = InteractiveTuiConfiguration()
    ) {
        self.chatContainer = chatContainer
        self.ui = ui
        self.tuiConfiguration = tuiConfiguration
    }

    public convenience init(
        session: AgentSession,
        version: String,
        changelogMarkdown: String? = nil,
        scopedModels: [ScopedModel] = [],
        customTools: [LoadedCustomTool] = [],
        mcpUi: InteractiveMcpUi? = nil,
        setToolUIContext: @escaping (HookUIContext, Bool) -> Void = { _, _ in },
        setToolSendMessageHandler: @escaping @Sendable (_ handler: @escaping HookSendMessageHandler) -> Void = { _ in },
        fdPath: String? = nil,
        verbose: Bool = false,
        tuiMode: InteractiveTuiMode? = nil,
        startupDiagnostics: [ResourceDiagnostic] = [],
        initialThemeSetting: String? = nil,
        terminal: Terminal? = nil,
        exitProcess: @escaping @MainActor (Int32) -> Void = { Darwin.exit($0) }
    ) {
        self.init(
            chatContainer: Container(),
            ui: NullRenderRequester(),
            tuiConfiguration: InteractiveTuiConfiguration(settingsManager: session.settingsManager, modeOverride: tuiMode)
        )
        self.tuiModeOverride = tuiMode
        self.startupDiagnostics = startupDiagnostics
        self.initialThemeSetting = initialThemeSetting
        self.injectedTerminal = terminal
        self.exitProcess = exitProcess
        self.session = session
        self.version = version
        self.changelogMarkdown = changelogMarkdown
        self.scopedModels = scopedModels
        self.customTools = Dictionary(uniqueKeysWithValues: customTools.map { ($0.tool.name, $0) })
        self.mcpUi = mcpUi
        self.setToolUIContext = setToolUIContext
        self.setToolSendMessageHandler = setToolSendMessageHandler
        self.fdPath = fdPath
        self.verboseStartup = verbose
        session.toolHtmlRenderer = TuiToolHtmlRenderer(theme: theme, cwd: session.sessionManager.getCwd(),
            getTheme: { theme }, getRenderers: { [weak self, weak session] name in
                guard let session else { return nil }
                return registeredToolRenderers(name, session: session, fallback: self?.customTools[name]?.tool)
            })
    }

    /// Construct a mounted component host for embedding and deterministic event tests.
    convenience init(session: AgentSession, tui: TUI, editor: EditorComponentView, renderer: AltScreenRenderer? = nil,
                     mcpUi: InteractiveMcpUi? = nil, tuiMode: InteractiveTuiMode? = nil, verbose: Bool = false) {
        self.init(session: session, version: VERSION, mcpUi: mcpUi, verbose: verbose, tuiMode: tuiMode)
        self.tui = tui
        self.ui = TuiRenderAdapter(tui)
        self.editor = editor
        self.defaultEditor = editor as? CustomEditor
        self.statusContainer = Container()
        self.editorContainer = Container()
        self.editorContainer?.addChild(editor)
        self.altScreenRenderer = renderer
    }

    public func start(
        initialMessages: [String] = [],
        initialMessage: String? = nil,
        initialImages: [ImageContent]? = nil
    ) async {
        await initializeIfNeeded()
        guard !isShuttingDown else { return }
        registerShutdownSignalHandlers()
        startBackgroundCatalogRefresh()
        if let session {
            pendingResourceDisplayOptions = ResourceDisplayOptions(
                extensionPaths: visibleStartupExtensionPaths(session.resourceLoader.getExtensions().paths),
                force: false
            )
        }
        renderInitialMessages()
        announceSavedCrashIfNeeded()
        renderStartupDiagnostics()
        tui?.requestRender(force: true)
        await tui?.waitForRender()
        emitOsc133("A") // initial prompt start

        if let initialMessage {
            await prompt(initialMessage, images: initialImages)
        }
        for message in initialMessages {
            await prompt(message, images: nil)
        }

        guard !isShuttingDown else { return }
        await withCheckedContinuation { continuation in
            self.exitContinuation = continuation
        }
    }

    /// Fire-and-forget catalog refresh at startup. Upstream moved this out of initialization
    /// deliberately: startup renders from the cached catalogs and never waits on the network.
    /// Skipped entirely when `PI_OFFLINE=1`.
    @MainActor
    private func startBackgroundCatalogRefresh() {
        guard let session, !isOfflineEnvironmentEnabled() else { return }
        backgroundCatalogRefreshTask = Task { @MainActor [weak self] in
            _ = await runBoundedCatalogRefresh(
                registry: session.modelRegistry,
                signal: CancellationToken()
            )
            // Failures are intentionally silent here: startup must not nag about a stale catalog.
            // The cached models stay on screen and the next explicit refresh reports errors.
            guard let self else { return }
            self.footer?.invalidate()
            self.ui.requestRender()
        }
    }

    private func initializeIfNeeded() async {
        guard !isInitialized, let session else { return }

        keybindings = KeybindingsManager.create()

        if tui == nil {
            applyInteractiveTerminalCapabilities(session.settingsManager)
            let created = TUI(terminal: terminalForNewTui, showHardwareCursor: session.settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            tui = created
            ui = TuiRenderAdapter(created)
        }
        guard let tui else { return }
        registerTerminalIOErrorHandler()
        tui.setClearOnShrink(session.settingsManager.getClearOnShrink())

        tui.onGlobalInput = { [weak self] data in
            guard let self else { return false }
            if self.keybindings.matches(data, .suspend) {
                self.handleCtrlZ()
                return true
            }
            if self.keybindings.matches(data, .clear) {
                if let selectorCancel = self.selectorCancel {
                    selectorCancel()
                } else {
                    self.handleCtrlC()
                }
                return true
            }
            return false
        }

        let settingsManager = session.settingsManager
        tuiConfiguration = InteractiveTuiConfiguration(
            settingsManager: settingsManager,
            modeOverride: tuiModeOverride
        )
        hideThinkingBlock = settingsManager.getHideThinkingBlock()

        themeController = InteractiveThemeController(ui: tui, getSettingsManager: { [weak self] in
            self?.session?.settingsManager ?? settingsManager
        }, showError: { [weak self] in self?.showError($0) }, onChanged: { [weak self] in
            self?.updateEditorBorderColor()
        }, initialThemeSetting: initialThemeSetting)

        let pendingMessages = Container()
        let status = Container()
        let widgets = Container()
        let defaultEditor = CustomEditor(
            ui: tui,
            theme: getEditorTheme(),
            keybindings: keybindings,
            options: EditorOptions(
                paddingX: settingsManager.getEditorPaddingX(),
                autocompleteMaxVisible: settingsManager.getAutocompleteMaxVisible()
            ),
            embedWorkingStatus: true
        )
        let editorContainer = Container()
        let footerDataProvider = FooterDataProvider()
        footerBranchUnsubscribe = footerDataProvider.onBranchChange { [weak tui] in
            Task { @MainActor in
                tui?.requestRender()
            }
        }
        let footer = FooterComponent(session: session, footerData: footerDataProvider)
        let footerContainer = Container()

        editorContainer.addChild(defaultEditor)
        footerContainer.addChild(footer)

        pendingMessagesContainer = pendingMessages
        statusContainer = status
        widgetContainer = widgets
        self.defaultEditor = defaultEditor
        self.editor = defaultEditor
        self.editorContainer = editorContainer
        self.footer = footer
        self.footerContainer = footerContainer
        self.footerDataProvider = footerDataProvider

        skills = session.resourceLoader.getSkills().skills
        setRegisteredThemes(session.resourceLoader.getThemes().themes)

        let slashCommands: [SlashCommand] = [
            SlashCommand(name: "settings", description: "Open settings menu"),
            SlashCommand(name: "config", description: "Configure resources"),
            SlashCommand(name: "model", description: "Select model"),
            SlashCommand(name: "thinking", description: "Set thinking level", argumentHint: "<level>", getArgumentCompletions: { [weak self] query in
                let levels = self?.session?.getAvailableThinkingLevels() ?? []
                let items = levels.map { AutocompleteItem(value: $0.rawValue, label: $0.rawValue) }
                return fuzzyFilter(items, query: query) { $0.value }
            }),
            SlashCommand(name: "share", description: "Share session as a private gist"),
            SlashCommand(name: "bug", description: "Export a local bug report", argumentHint: "[description]"),
            SlashCommand(name: "trust", description: "Manage project trust"),
            SlashCommand(name: "scoped-models", description: "Enable/disable models for Ctrl+P cycling"),
            SlashCommand(name: "theme", description: "Select theme"),
            SlashCommand(
                name: "login",
                description: "Configure provider authentication",
                argumentHint: "<provider>",
                getArgumentCompletions: { [weak self] query in
                    guard let registry = self?.session?.modelRegistry else { return nil }
                    return getLoginProviderCompletions(registry, query: query)
                }
            ),
            SlashCommand(name: "logout", description: "Remove provider authentication"),
            SlashCommand(name: "templates", description: "List prompt templates"),
            SlashCommand(name: "reload", description: "Reload skills, prompts, themes"),
            SlashCommand(name: "export", description: "Export session to HTML"),
            SlashCommand(name: "copy", description: "Copy selection or last assistant message"),
            SlashCommand(name: "name", description: "Set session display name"),
            SlashCommand(name: "session", description: "Show session info"),
            SlashCommand(name: "files", description: "Show file operations in this session"),
            SlashCommand(name: "changelog", description: "Show changelog"),
            SlashCommand(name: "hotkeys", description: "Show shortcuts"),
            SlashCommand(name: "debug", description: "Show theme diagnostics"),
            SlashCommand(name: "fork", description: "Create a new fork from a previous message"),
            SlashCommand(name: "clone", description: "Duplicate the current branch into a new session"),
            SlashCommand(name: "tree", description: "Navigate session tree"),
            SlashCommand(name: "new", description: "Start a new session"),
            SlashCommand(name: "compact", description: "Compact session"),
            SlashCommand(name: "resume", description: "Resume a session"),
            SlashCommand(name: "quit", description: "Exit the agent"),
            SlashCommand(name: "exit", description: "Exit the agent"),
        ]

        baseSlashCommands = slashCommands
        rebuildAutocomplete()

        var transcriptChildren: [Component] = []
        let addTranscriptChild: (Component) -> Void = { component in
            tui.addChild(component)
            transcriptChildren.append(component)
        }

        addTranscriptChild(startupHeaderContainer)
        addTranscriptChild(loadedResourcesContainer)

        tui.addChild(chatContainer)
        transcriptChildren.append(chatContainer)
        tui.addChild(pendingMessages)
        tui.addChild(status)
        tui.addChild(widgets)
        let editorSpacer = Spacer(1)
        tui.addChild(editorSpacer)
        tui.addChild(editorContainer)
        tui.addChild(footerContainer)

        let composition = InteractiveComposition(
            transcriptChildren: transcriptChildren,
            pendingMessages: pendingMessages,
            status: status,
            widgets: widgets,
            editorSpacer: editorSpacer,
            editor: editorContainer,
            footer: footerContainer,
            scrollbar: tuiConfiguration.scrollbar,
            scrollbarStyle: fullscreenScrollbarStyle
        )
        self.composition = composition
        let altScreenRenderer = tui.enableAltScreen(options: interactiveAltScreenOptions(
            wheelScrollLines: tuiConfiguration.mouseWheelStep,
            copyOnSelect: settingsManager.getFullscreenCopyOnSelect(),
            onRightClickPaste: { [weak self] in self?.handleClipboardImagePaste() },
            fullscreenWheelScrollLines: tuiConfiguration.fullscreenWheelScrollLines
        ))
        altScreenRenderer.setLayoutRoot(composition.fullscreenRoot)
        self.altScreenRenderer = altScreenRenderer
        if tuiConfiguration.mode == .fullscreen {
            _ = tui.switchRenderer(to: .altScreen)
        }
        tui.setFocus(defaultEditor)
        defaultEditor.onAction(.clear) { [weak self] in self?.handleCtrlC() }
        defaultEditor.onAction(.exit) { [weak self] in self?.handleCtrlD() }
        defaultEditor.onSubmit = { [weak self] text in self?.handleStartupSubmit(text) }
        tui.start()
        programStatus.report()
        guard !isShuttingDown else { return }

        themeController?.applyFromSettings()
        await themeController?.waitForTerminalColors()

        refreshStartupHeader()

        tui.requestRender()

        let statuses = ManagedToolStatuses()
        async let installedFd = ensureTool("fd", onStatus: { [weak self] status in
            statuses.append(status)
            Task { @MainActor [weak self] in self?.drainManagedToolStatuses(statuses) }
        })
        async let installedRg = ensureTool("rg", onStatus: { [weak self] status in
            statuses.append(status)
            Task { @MainActor [weak self] in self?.drainManagedToolStatuses(statuses) }
        })
        let (fd, _) = await (installedFd, installedRg)
        guard !isShuttingDown else { return }
        fdPath = fd
        drainManagedToolStatuses(statuses)
        rebuildAutocomplete()
        subscribeToAgent()
        await initializeHooksAndCustomTools()
        configureKeyHandlers()

        onThemeChange { [weak self] in
            Task { @MainActor in
                self?.updateEditorBorderColor()
                self?.tui?.invalidate()
                self?.tui?.requestRender()
            }
        }

        updateTerminalTitle()

        isInitialized = true

        if let tmuxWarning = await checkTmuxKeyboardSetup() {
            showWarning(tmuxWarning)
        }
    }

    @MainActor
    func refreshStartupHeader() {
        guard let settingsManager = session?.settingsManager else { return }
        let headerContainer = startupHeaderContainer
        headerContainer.clear()
        builtInHeader = nil
        let shouldShowHeader = settingsManager.getQuietStartup().showsStartupHeader(verbose: verboseStartup)
        if shouldShowHeader {
            let version = self.version
            let keybindings = self.keybindings
            let showDetails = settingsManager.getQuietStartup().showsStartupDetails(verbose: verboseStartup)
            let header = ExpandableText(
                collapsed: { buildStartupHeader(version: version, keybindings: keybindings, expanded: false, showDetails: showDetails) },
                expanded: { buildStartupHeader(version: version, keybindings: keybindings, expanded: true, showDetails: showDetails) },
                isExpanded: verboseStartup || toolOutputExpanded, paddingX: 1, paddingY: 0
            )
            builtInHeader = header
            headerContainer.addChild(Spacer(1))
            headerContainer.addChild(header)
            headerContainer.addChild(Spacer(1))

            if let changelogMarkdown, !changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headerContainer.addChild(DynamicBorder())
                if settingsManager.getCollapseChangelog() {
                    let condensed = "Updated. Use /changelog to view details."
                    headerContainer.addChild(Text(condensed, paddingX: 1, paddingY: 0))
                } else {
                    headerContainer.addChild(ThemedText({ theme.bold(theme.fg(.accent, "What's New")) }, paddingX: 1, paddingY: 0))
                    headerContainer.addChild(Spacer(1))
                    headerContainer.addChild(Markdown(changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines), paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
                    headerContainer.addChild(Spacer(1))
                }
                headerContainer.addChild(DynamicBorder())
            }
        } else {
            headerContainer.addChild(Text("", paddingX: 0, paddingY: 0))
            if let changelogMarkdown, !changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headerContainer.addChild(Spacer(1))
                let condensed = "Updated. Use /changelog to view details."
                headerContainer.addChild(Text(condensed, paddingX: 1, paddingY: 0))
            }
        }
    }

    @MainActor
    @discardableResult
    func switchTuiMode(_ mode: InteractiveTuiMode) -> Bool {
        guard let tui else { return false }
        if tui.hasOverlay() { return false }
        let rendererMode: TuiMode = mode == .fullscreen ? .altScreen : .mainScreen
        guard tui.switchRenderer(to: rendererMode) else { return false }
        tuiConfiguration.mode = mode
        mountWorkingIndicator()
        return true
    }

    @MainActor
    private func setFullscreenScrollbar(_ mode: FullscreenScrollbarMode) {
        tuiConfiguration.scrollbar = mode
        composition?.transcriptScrollView.setScrollbar(mode.miniTuiValue)
        tui?.requestRender()
    }

    @MainActor
    func setFullscreenWheelScrollLines(_ lines: PiSwiftCodingAgent.WheelScrollLines) {
        tuiConfiguration.fullscreenWheelScrollLines = lines
        altScreenRenderer?.setWheelScrollLines(lines.miniTuiValue)
    }

    @MainActor
    private func refreshMarkdownRendering() {
        renderInitialMessages()
        if let streamingComponent, let streamingMessage {
            streamingComponent.setMarkdownConfiguration(tuiConfiguration)
            streamingComponent.updateContent(streamingMessage)
            chatContainer.addChild(streamingComponent)
        }
        scheduleRender()
    }

    @MainActor
    func updateTerminalTitle() {
        programStatus.handleEvent(.sessionInfoChanged)
        guard let tui else { return }
        let cwdBase = FileManager.default.currentDirectoryPath.split(separator: "/").last.map(String.init)
            ?? FileManager.default.currentDirectoryPath
        if let sessionName = session?.sessionManager.getSessionName(), !sessionName.isEmpty {
            tui.terminal.setTitle("pi - \(sessionName) - \(cwdBase)")
        } else {
            tui.terminal.setTitle("pi - \(cwdBase)")
        }
    }

    private func checkTmuxKeyboardSetup() async -> String? {
        guard ProcessInfo.processInfo.environment["TMUX"] != nil else { return nil }

        async let extKeys = runTmuxShow("extended-keys")
        async let extFormat = runTmuxShow("extended-keys-format")

        let (keys, format) = await (extKeys, extFormat)

        guard let keys else { return nil }
        if keys != "on" && keys != "always" {
            return "tmux extended-keys is off. Run: tmux set -g extended-keys on"
        }
        if format == "xterm" {
            return "tmux extended-keys-format is xterm. For best results: tmux set -g extended-keys-format csi-u"
        }
        return nil
    }

    private func runTmuxShow(_ option: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "show", "-gv", option]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Simple timeout: if process doesn't exit in 2 seconds, terminate
            let task = Task {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            task.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    @MainActor
    private func setAutocompleteCommands(_ commands: [SlashCommand]) {
        guard let defaultEditor else { return }
        let provider = CombinedAutocompleteProvider(
            commands: commands,
            items: [],
            basePath: FileManager.default.currentDirectoryPath,
            fdPath: fdPath
        )
        autocompleteProvider = provider
        let stacked = applyAutocompleteWrappers(to: provider)
        stackedAutocompleteProvider = stacked
        defaultEditor.setAutocompleteProvider(stacked)
    }

    @MainActor
    private func applyAutocompleteWrappers(to base: AutocompleteProvider) -> AutocompleteProvider {
        var current: AutocompleteProvider = base
        for wrap in autocompleteProviderWrappers {
            current = wrap(current)
        }
        return current
    }

    /// v0.70.5: register an autocomplete provider wrapper from an extension. The factory
    /// receives the current provider and returns a wrapped replacement. Wrappers stack in
    /// registration order on top of the base CombinedAutocompleteProvider.
    @MainActor
    func addAutocompleteProvider(_ factory: @escaping @MainActor @Sendable (AutocompleteProvider) -> AutocompleteProvider) {
        autocompleteProviderWrappers.append(factory)
        guard let base = autocompleteProvider, let defaultEditor else { return }
        let stacked = applyAutocompleteWrappers(to: base)
        stackedAutocompleteProvider = stacked
        defaultEditor.setAutocompleteProvider(stacked)
    }

    @MainActor
    private func buildSkillCommands(_ settingsManager: SettingsManager) -> [SlashCommand] {
        skillCommands.removeAll()
        guard settingsManager.getEnableSkillCommands() else { return [] }
        var list: [SlashCommand] = []
        for skill in skills {
            let commandName = "skill:\(skill.name)"
            skillCommands[commandName] = skill.filePath
            list.append(SlashCommand(name: commandName, description: skill.description))
        }
        return list
    }

    @MainActor
    private func rebuildAutocomplete() {
        guard let session else { return }
        let templateCommands = session.promptTemplates.map { template in
            SlashCommand(name: template.name, description: template.description)
        }
        let hookCommands = session.hookRunner?.getRegisteredCommands().map { command in
            SlashCommand(name: command.name, description: command.description ?? "(hook command)")
        } ?? []
        let skillList = buildSkillCommands(session.settingsManager)
        setAutocompleteCommands(baseSlashCommands + templateCommands + hookCommands + skillList)
    }

    @MainActor
    func initializeHooksAndCustomTools() async {
        guard let session else { return }

        mcpUi?.attach(custom: { [weak self] factory in
            guard let self else { return nil }
            return await self.showHookCustom(factory, options: nil)
        }, requestRender: { [weak self] in
            self?.ui.requestRender()
        }, notify: { [weak self] message in
            self?.showHookNotify(message, .error)
        })

        let uiContext = InteractiveHookUIContext(
            select: { [weak self] title, options in
                guard let self else { return nil }
                return await self.showHookSelector(title, options)
            },
            confirm: { [weak self] title, message in
                guard let self else { return false }
                return await self.showHookConfirm(title, message)
            },
            input: { [weak self] title, placeholder in
                guard let self else { return nil }
                return await self.showHookInput(title, placeholder)
            },
            notify: { [weak self] message, type in
                Task { @MainActor in
                    self?.showHookNotify(message, type)
                }
            },
            setStatus: { [weak self] key, text in
                Task { @MainActor in
                    self?.setHookStatus(key, text)
                }
            },
            setWorkingMessage: { [weak self] message in
                Task { @MainActor in
                    self?.setWorkingMessage(message)
                }
            },
            setWorkingVisible: { [weak self] visible in
                self?.setWorkingVisible(visible)
            },
            setWorkingIndicator: { [weak self] options in
                self?.setWorkingIndicator(options)
            },
            setHiddenThinkingLabel: { [weak self] label in
                self?.setHiddenThinkingLabel(label)
            },
            addAutocompleteProvider: { [weak self] factory in
                self?.addAutocompleteProvider { [weak self] provider in
                    guard let wrapped = factory(provider) as? any AutocompleteProvider else {
                        self?.showWarning("Autocomplete factory must return an AutocompleteProvider.")
                        return provider
                    }
                    return wrapped
                }
            },
            setWidget: { [weak self] key, content in
                Task { @MainActor in
                    self?.setHookWidget(key, content)
                }
            },
            setFooter: { [weak self] factory in
                Task { @MainActor in
                    self?.setCustomFooter(factory)
                }
            },
            setTitle: { [weak self] title in
                Task { @MainActor in
                    self?.tui?.terminal.setTitle(title)
                }
            },
            custom: { [weak self] factory, options in
                guard let self else { return nil }
                return await self.showHookCustom(factory, options: options)
            },
            pasteToEditor: { [weak self] text in
                Task { @MainActor in
                    self?.editor?.handleInput("\u{001B}[200~\(text)\u{001B}[201~")
                }
            },
            setEditorText: { [weak self] text in
                Task { @MainActor in
                    self?.editor?.setText(text)
                }
            },
            getEditorText: { [weak self] in
                guard let self else { return "" }
                // Return expanded text so extensions get actual content, not paste markers
                return self.editor?.getExpandedText() ?? ""
            },
            editor: { [weak self] title, prefill in
                guard let self else { return nil }
                return await self.showHookEditor(title, prefill)
            },
            setEditorComponent: { [weak self] factory in
                Task { @MainActor in
                    self?.setCustomEditorComponent(factory)
                }
            },
            getAllThemes: {
                getAvailableThemesWithPaths()
            },
            getTheme: { name in
                getThemeByName(name)
            },
            setTheme: { [weak self] selection in
                guard let self else { return HookThemeResult(success: false, error: "UI not available") }
                switch selection {
                case .name(let name):
                    let result = self.themeController?.setThemeName(name) ?? setTheme(name, enableWatcher: true)
                    if result.success {
                        self.session?.settingsManager.setTheme(name)
                        self.ui.requestRender()
                        return HookThemeResult(success: true)
                    }
                    return HookThemeResult(success: false, error: result.error)
                case .theme(let theme):
                    self.themeController?.setThemeInstance(theme)
                    self.ui.requestRender()
                    return HookThemeResult(success: true)
                }
            },
            getToolsExpanded: { [weak self] in
                self?.toolOutputExpanded ?? false
            },
            setToolsExpanded: { [weak self] expanded in
                Task { @MainActor in
                    self?.setToolsExpanded(expanded)
                }
            },
            themeProvider: { theme }
        )

        if !customTools.isEmpty {
            let labels = customTools.values.map { "  \($0.tool.name) (\($0.path))" }
            chatContainer.addChild(ThemedText({
                theme.fg(.muted, "Loaded custom tools:\n") + labels.map { theme.fg(.dim, $0) }.joined(separator: "\n")
            }, paddingX: 0, paddingY: 0))
            chatContainer.addChild(Spacer(1))
            scheduleRender()
        }

        setToolUIContext(uiContext, true)
        setToolSendMessageHandler { [weak session, weak self] message, options in
            guard let session else { return }
            let shouldRefresh = !session.isStreaming
                && options?.triggerTurn != true
                && options?.deliverAs != .nextTurn
                && message.display
            Task {
                await session.sendHookMessage(message, options: options)
                if shouldRefresh {
                    Task { @MainActor [weak self] in
                        self?.renderInitialMessages()
                    }
                }
            }
        }
        await session.emitCustomToolSessionEvent(.start, previousSessionFile: nil)

        guard let hookRunner = session.hookRunner else { return }

        hookRunner.initialize(
            getModel: { [weak session] in session?.agent.state.model },
            getSystemPrompt: { [weak session] in session?.agent.state.systemPrompt },
            getSystemPromptOptions: { [weak session] in
                session?.getCurrentSystemPromptOptions() ?? BuildSystemPromptOptions()
            },
            isProjectTrusted: { [weak session] in session?.projectTrusted ?? true },
            sendMessageHandler: { [weak session, weak self] message, options in
                guard let session else { return }
                let shouldRefresh = !session.isStreaming
                    && options?.triggerTurn != true
                    && options?.deliverAs != .nextTurn
                    && message.display
                Task {
                    await session.sendHookMessage(message, options: options)
                    if shouldRefresh {
                        Task { @MainActor [weak self] in
                            self?.renderInitialMessages()
                        }
                    }
                }
            },
            appendEntryHandler: { [weak session, weak self] customType, data in
                _ = session?.sessionManager.appendCustomEntry(customType, data)
                // A persisted display-only entry may arrive while the assistant is still
                // streaming. Rebuild the persisted transcript and restore the live
                // assistant last so the visual order mirrors the session file.
                Task { @MainActor in
                    guard let self, self.streamingComponent != nil else { return }
                    self.renderInitialMessages()
                    if let streamingComponent = self.streamingComponent {
                        self.chatContainer.addChild(streamingComponent)
                    }
                    self.scheduleRender()
                }
            },
            setSessionNameHandler: { [weak session, weak self] name in
                _ = session?.sessionManager.appendSessionInfo(name)
                Task { @MainActor [weak self] in
                    self?.updateTerminalTitle()
                }
            },
            getSessionNameHandler: { [weak session] in
                session?.sessionManager.getSessionName()
            },
            getActiveToolsHandler: { [weak session] in
                session?.getActiveToolNames() ?? []
            },
            getAllToolsHandler: { [weak session] in
                session?.getAllTools() ?? []
            },
            setActiveToolsHandler: { [weak session] toolNames in
                session?.setActiveToolsByName(toolNames)
            },
            newSessionHandler: { [weak self] options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookNewSession(options)
            },
            forkHandler: { [weak self] entryId in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookFork(entryId)
            },
            navigateTreeHandler: { [weak self] targetId, options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.handleHookNavigateTree(targetId, options: options)
            },
            isIdle: { [weak session] in
                !(session?.isStreaming ?? true)
            },
            waitForIdle: { [weak session] in
                await session?.waitForIdle()
            },
            abort: { [weak session] in
                Task {
                    await session?.abort()
                }
            },
            hasPendingMessages: { [weak session] in
                (session?.pendingMessageCount ?? 0) > 0
            },
            uiContext: uiContext,
            mode: .tui,
            hasUI: true
        )

        _ = hookRunner.onError { [weak self] error in
            Task { @MainActor in
                self?.showHookError(error.hookPath, error.error, error.stack)
            }
        }

        setupHookShortcuts(hookRunner)

        _ = await hookRunner.emit(SessionStartEvent())

        rebuildAutocomplete()

        let hookPaths = hookRunner.getHookPaths()
        if !hookPaths.isEmpty {
            chatContainer.addChild(ThemedText({
                theme.fg(.muted, "Loaded hooks:\n") + hookPaths.map { theme.fg(.dim, "  \($0)") }.joined(separator: "\n")
            }, paddingX: 0, paddingY: 0))
            chatContainer.addChild(Spacer(1))
            scheduleRender()
        }
    }

    @MainActor
    private func handleHookNewSession(_ options: HookNewSessionOptions?) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }

        loadingAnimation?.stop()
        loadingAnimation = nil
        clearWorkingIndicator()

        _ = session.sessionManager.newSession(NewSessionOptions(parentSession: options?.parentSession))

        if let setup = options?.setup {
            await setup(session.sessionManager)
        }
        // v0.87.1: the session is canonical; rebuild agent state from it (includes setup entries).
        session.refreshContext()
        reportingManualCompaction = false
        programStatus.reset()
        altScreenRenderer?.resetTextSelection()

        chatContainer.clear()
        pendingMessagesContainer?.clear()
        streamingComponent = nil
        streamingMessage = nil
        pendingTools.removeAll()

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.accent, "✓ New session started") }, paddingX: 1, paddingY: 0))
        scheduleRender()

        return HookCommandResult(cancelled: false)
    }

    @MainActor
    private func handleHookFork(_ entryId: String) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }

        do {
            let result = try await session.fork(entryId)
            if result.cancelled {
                return HookCommandResult(cancelled: true)
            }

            reportingManualCompaction = false
            programStatus.reset()
            chatContainer.clear()
            renderInitialMessages()
            editor?.setText(result.selectedText)
            showStatus("Forked to new session")
            return HookCommandResult(cancelled: false)
        } catch {
            showHookError("fork", error.localizedDescription)
            return HookCommandResult(cancelled: true)
        }
    }

    @MainActor
    private func handleHookNavigateTree(_ targetId: String, options: HookNavigateTreeOptions?) async -> HookCommandResult {
        guard let session else { return HookCommandResult(cancelled: true) }
        guard !session.isCompacting else { return HookCommandResult(cancelled: true) }
        if options?.summarize == true { setTransientStatus("Summarizing branch") }
        defer { if transientStatusMessage == "Summarizing branch" { setTransientStatus(nil) } }

        let result = await session.navigateTree(
            targetId,
            summarize: options?.summarize ?? false,
            customInstructions: options?.customInstructions,
            replaceInstructions: options?.replaceInstructions,
            label: options?.label
        )
        guard !session.isCompacting else { return HookCommandResult(cancelled: true) }
        if result.cancelled {
            return HookCommandResult(cancelled: true)
        }

        chatContainer.clear()
        renderInitialMessages()
        if let editorText = result.editorText {
            editor?.setText(editorText)
        }
        showStatus("Navigated to selected point")
        return HookCommandResult(cancelled: false)
    }

    @MainActor
    func showHookSelector(_ title: String, _ options: [String], blocked: BlockedStatus? = nil) async -> String? {
        guard editorContainer != nil, tui != nil else { return nil }
        programStatus.setBlocked(source: "extension-dialog", status: blocked ?? BlockedStatus(kind: .question, message: title))
        defer { programStatus.setBlocked(source: "extension-dialog", status: nil) }
        return await withCheckedContinuation { continuation in
            showSelector { done in
                let selector = HookSelectorComponent(
                    title: title,
                    options: options,
                    onSelect: { [weak self] option in
                        self?.hookSelector = nil
                        done()
                        continuation.resume(returning: option)
                    },
                    onCancel: { [weak self] in
                        self?.hookSelector = nil
                        done()
                        continuation.resume(returning: nil)
                    }
                )
                self.hookSelector = selector
                return (component: selector, focus: selector)
            }
        }
    }

    @MainActor
    func showHookConfirm(_ title: String, _ message: String) async -> Bool {
        let choice = await showHookSelector("\(title)\n\(message)", ["Yes", "No"], blocked: BlockedStatus(kind: .permission, message: title))
        return choice == "Yes"
    }

    @MainActor
    func showHookInput(_ title: String, _ placeholder: String?) async -> String? {
        guard editorContainer != nil, tui != nil, !Task.isCancelled else { return nil }
        @MainActor final class InputWait {
            var cancel: (() -> Void)?
        }
        let wait = InputWait()
        programStatus.setBlocked(source: "extension-dialog", status: BlockedStatus(kind: .question, message: title))
        defer { programStatus.setBlocked(source: "extension-dialog", status: nil) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                showSelector { done in
                    var completed = false
                    let finish: (String?) -> Void = { [weak self] value in
                        guard !completed else { return }
                        completed = true
                        wait.cancel = nil
                        self?.hookInput = nil
                        done()
                        continuation.resume(returning: value)
                    }
                    let input = HookInputComponent(
                        title: title,
                        placeholder: placeholder,
                        onSubmit: { finish($0) },
                        onCancel: { finish(nil) }
                    )
                    wait.cancel = { finish(nil) }
                    self.hookInput = input
                    return (component: input, focus: input)
                }
                if Task.isCancelled { wait.cancel?() }
            }
        } onCancel: {
            Task { @MainActor in wait.cancel?() }
        }
    }

    @MainActor
    func showHookEditor(_ title: String, _ prefill: String?) async -> String? {
        guard editorContainer != nil, tui != nil else { return nil }
        programStatus.setBlocked(source: "extension-dialog", status: BlockedStatus(kind: .question, message: title))
        defer { programStatus.setBlocked(source: "extension-dialog", status: nil) }
        return await withCheckedContinuation { continuation in
            guard let tui else {
                continuation.resume(returning: nil)
                return
            }
            showSelector { done in
                let editor = HookEditorComponent(
                    tui: tui,
                    title: title,
                    prefill: prefill,
                    onSubmit: { [weak self] value in
                        self?.hookEditor = nil
                        done()
                        continuation.resume(returning: value)
                    },
                    onCancel: { [weak self] in
                        self?.hookEditor = nil
                        done()
                        continuation.resume(returning: nil)
                    }
                )
                self.hookEditor = editor
                return (component: editor, focus: editor)
            }
        }
    }

    @MainActor
    private func showHookCustom(
        _ factory: @escaping HookCustomFactory,
        options: HookCustomOptions?
    ) async -> HookCustomResult? {
        guard let tui, let editor, let editorContainer else { return nil }
        let savedText = editor.getText()
        let isOverlay = options?.overlay ?? false

        func restoreEditor() {
            editorContainer.clear()
            editorContainer.addChild(editor)
            editor.setText(savedText)
            tui.setFocus(editor)
            tui.requestRender()
        }

        return await withCheckedContinuation { continuation in
            var component: Component?
            var overlayHandle: HookOverlayHandle?
            var closed = false

            let close: HookCustomClose = { result in
                guard !closed else { return }
                closed = true
                if let disposable = component as? HookDisposableComponent {
                    disposable.dispose()
                }
                if isOverlay {
                    overlayHandle?.hide()
                    tui.requestRender()
                } else {
                    restoreEditor()
                }
                continuation.resume(returning: result.map(HookCustomResult.init))
            }

            Task { @MainActor in
                let created = await factory(tui, theme, keybindings, close)
                guard !closed else { return }
                guard let createdComponent = created as? Component else { return }
                component = createdComponent
                if isOverlay {
                    let resolvedOptions = resolveOverlayOptions(options?.overlayOptions)
                    let handle = tui.showOverlay(createdComponent, options: resolvedOptions)
                    let wrapper = TuiOverlayHandle(handle)
                    overlayHandle = wrapper
                    options?.onHandle?(wrapper)
                    tui.requestRender()
                } else {
                    editorContainer.clear()
                    editorContainer.addChild(createdComponent)
                    tui.setFocus(createdComponent)
                    tui.requestRender()
                }
            }
        }
    }

    @MainActor
    private func resolveOverlayOptions(_ source: HookOverlayOptionsSource?) -> OverlayOptions? {
        guard let source else { return nil }
        let resolved: HookOverlayOptions
        switch source {
        case .fixed(let options):
            resolved = options
        case .dynamic(let provider):
            resolved = provider()
        }
        return convertOverlayOptions(resolved)
    }

    @MainActor
    private func convertOverlayOptions(_ options: HookOverlayOptions) -> OverlayOptions {
        OverlayOptions(
            width: options.width.map(convertOverlaySize),
            minWidth: options.minWidth,
            maxHeight: options.maxHeight.map(convertOverlaySize),
            anchor: options.anchor.map(convertOverlayAnchor),
            offsetX: options.offsetX,
            offsetY: options.offsetY,
            row: options.row.map(convertOverlaySize),
            col: options.col.map(convertOverlaySize),
            margin: options.margin.map { OverlayMargin(top: $0.top, right: $0.right, bottom: $0.bottom, left: $0.left) }
        )
    }

    @MainActor
    private func convertOverlayAnchor(_ anchor: HookOverlayAnchor) -> OverlayAnchor {
        switch anchor {
        case .center: return .center
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .topCenter: return .topCenter
        case .bottomCenter: return .bottomCenter
        case .leftCenter: return .leftCenter
        case .rightCenter: return .rightCenter
        }
    }

    @MainActor
    private func convertOverlaySize(_ size: HookOverlaySize) -> SizeValue {
        switch size {
        case .absolute(let value):
            return .absolute(value)
        case .percent(let value):
            return .percent(Double(value))
        }
    }

    @MainActor
    private func showHookNotify(_ message: String, _ type: HookNotificationType?) {
        switch type {
        case .error:
            showError(message)
        case .warning:
            showWarning(message)
        case .info, .none:
            showStatus(message)
        }
    }

    @MainActor
    private func setWorkingMessage(_ message: String?) {
        workingMessage = message
        if let loadingAnimation {
            loadingAnimation.setMessage(message ?? defaultWorkingMessage)
        }
    }

    @MainActor
    func setWorkingVisible(_ visible: Bool) {
        workingVisible = visible
        if !visible {
            clearWorkingIndicator()
        } else if session?.isStreaming == true, loadingAnimation != nil {
            mountWorkingIndicator()
        }
        ui.requestRender()
    }

    @MainActor
    func setWorkingIndicator(_ options: WorkingIndicatorOptions?) {
        workingIndicatorOptions = options
        if let loadingAnimation {
            if let options {
                loadingAnimation.setIndicator(LoaderIndicatorOptions(frames: options.frames, intervalMs: options.intervalMs))
            } else {
                // MiniTui retains omitted options. Replace the loader to restore its defaults.
                loadingAnimation.stop()
                clearWorkingIndicator()
                self.loadingAnimation = makeWorkingIndicator()
                mountWorkingIndicator()
            }
        }
        ui.requestRender()
    }

    @MainActor
    func setHiddenThinkingLabel(_ label: String?) {
        hiddenThinkingLabel = label
        for case let component as AssistantMessageComponent in chatContainer.children {
            component.setHiddenThinkingLabel(label)
        }
        streamingComponent?.setHiddenThinkingLabel(label)
        ui.requestRender()
    }

    private func makeWorkingIndicator() -> WorkingStatusIndicator? {
        guard let tui else { return nil }
        let embedded = (editor as? any WorkingStatusEditor)?.embedWorkingStatus == true
        let color: ((String) -> String)? = embedded ? { [weak self] text in
            self?.editor?.borderColor(text) ?? theme.fg(.muted, text)
        } : nil
        let indicator = workingIndicatorOptions.map {
            LoaderIndicatorOptions(frames: $0.frames, intervalMs: $0.intervalMs)
        }
        return WorkingStatusIndicator(ui: tui, message: workingMessage ?? defaultWorkingMessage,
                                      indicator: indicator, colorFn: color)
    }

    @MainActor
    private func setHookStatus(_ key: String, _ text: String?) {
        footerDataProvider?.setExtensionStatus(key, text)
        scheduleRender()
    }

    @MainActor
    private func setupHookShortcuts(_ hookRunner: HookRunner) {
        hookShortcuts = hookRunner.getShortcuts()
        guard let defaultEditor else { return }
        if hookShortcuts.isEmpty {
            defaultEditor.onHookShortcut = nil
            return
        }
        defaultEditor.onHookShortcut = { [weak self, weak hookRunner] data in
            guard let self, let hookRunner else { return false }
            for (key, shortcut) in self.hookShortcuts {
                if matchesKey(data, key) {
                    Task { @MainActor in
                        let context = hookRunner.createShortcutContext()
                        await shortcut.handler(context)
                    }
                    return true
                }
            }
            return false
        }
    }

    @MainActor
    private func setHookWidget(_ key: String, _ content: HookWidgetContent?) {
        if let existing = hookWidgets[key] {
            if let disposable = existing as? HookDisposableComponent {
                disposable.dispose()
            }
        }

        if content == nil {
            hookWidgets.removeValue(forKey: key)
            hookWidgetOrder.removeAll { $0 == key }
            renderWidgets()
            return
        }

        guard let tui else { return }

        if hookWidgets[key] == nil {
            hookWidgetOrder.append(key)
        }

        switch content {
        case .lines(let lines):
            let container = Container()
            let limitedLines = Array(lines.prefix(Self.maxWidgetLines))
            for line in limitedLines {
                container.addChild(Text(line, paddingX: 1, paddingY: 0))
            }
            if lines.count > Self.maxWidgetLines {
                container.addChild(ThemedText({ theme.fg(.muted, "... (widget truncated)") }, paddingX: 1, paddingY: 0))
            }
            hookWidgets[key] = container
        case .component(let factory):
            if let component = factory(tui, theme) as? Component {
                hookWidgets[key] = component
            }
        case .none:
            break
        }

        renderWidgets()
    }

    @MainActor
    private func setCustomFooter(_ factory: HookFooterFactory?) {
        guard let tui, let footerContainer, let footer, let footerDataProvider else { return }

        if let customFooter, let disposable = customFooter as? HookDisposableComponent {
            disposable.dispose()
        }

        footerContainer.clear()

        if let factory {
            if let component = factory(tui, theme, footerDataProvider) as? Component {
                customFooter = component
                footerContainer.addChild(component)
            } else {
                customFooter = nil
                footerContainer.addChild(footer)
            }
        } else {
            customFooter = nil
            footerContainer.addChild(footer)
        }

        tui.requestRender()
    }

    @MainActor
    private func setCustomEditorComponent(_ factory: HookEditorComponentFactory?) {
        guard let tui, let editorContainer, let defaultEditor else { return }
        let currentText = editor?.getText() ?? ""

        editorContainer.clear()

        if let factory {
            let created = factory(tui, getEditorTheme(), keybindings)
            if let newEditor = created as? EditorComponentView {
                newEditor.onSubmit = defaultEditor.onSubmit
                newEditor.onChange = defaultEditor.onChange
                newEditor.setText(currentText)
                newEditor.borderColor = defaultEditor.borderColor

                if let provider = stackedAutocompleteProvider ?? autocompleteProvider {
                    newEditor.setAutocompleteProvider(provider)
                }
                if let settingsManager = session?.settingsManager {
                    newEditor.setPaddingX(settingsManager.getEditorPaddingX())
                    newEditor.setAutocompleteMaxVisible(settingsManager.getAutocompleteMaxVisible())
                }

                if let customEditor = newEditor as? CustomEditor {
                    customEditor.onEscape = defaultEditor.onEscape
                    customEditor.onCtrlD = defaultEditor.onCtrlD
                    customEditor.onPasteImage = defaultEditor.onPasteImage
                    customEditor.onHookShortcut = defaultEditor.onHookShortcut
                    customEditor.actionHandlers = defaultEditor.actionHandlers
                }

                editor = newEditor
            } else {
                defaultEditor.setText(currentText)
                if let settingsManager = session?.settingsManager {
                    defaultEditor.setPaddingX(settingsManager.getEditorPaddingX())
                    defaultEditor.setAutocompleteMaxVisible(settingsManager.getAutocompleteMaxVisible())
                }
                editor = defaultEditor
            }
        } else {
            defaultEditor.setText(currentText)
            if let settingsManager = session?.settingsManager {
                defaultEditor.setPaddingX(settingsManager.getEditorPaddingX())
            }
            editor = defaultEditor
        }

        if let editor {
            editorContainer.addChild(editor)
            tui.setFocus(editor)
            mountWorkingIndicator()
        tui.requestRender()
        }
    }

    @MainActor
    private func renderWidgets() {
        guard let widgetContainer else { return }
        widgetContainer.clear()

        for key in hookWidgetOrder {
            if let component = hookWidgets[key] {
                widgetContainer.addChild(component)
            }
        }

        scheduleRender()
    }

    @MainActor
    private func showHookError(_ hookPath: String, _ error: String, _ stack: String? = nil) {
        let errorText = ThemedText({
            theme.fg(.error, "Hook \"\(hookPath)\" error: \(error)") },
            paddingX: tuiConfiguration.outputPad,
            paddingY: 0
        )
        chatContainer.addChild(errorText)
        if let stack, !stack.isEmpty {
            let lines = stack.split(separator: "\n").dropFirst()
            if !lines.isEmpty {
                let stackLines = lines.map { "  \($0.trimmingCharacters(in: .whitespaces))" }
                chatContainer.addChild(ThemedText({
                    stackLines.map { theme.fg(.dim, $0) }.joined(separator: "\n") },
                    paddingX: tuiConfiguration.outputPad,
                    paddingY: 0
                ))
            }
        }
        scheduleRender()
    }

    @MainActor
    private func configureKeyHandlers() {
        guard let defaultEditor else { return }

        defaultEditor.onEscape = { [weak self] in
            self?.handleEscape()
        }
        defaultEditor.onCtrlD = { [weak self] in
            self?.handleCtrlD()
        }
        defaultEditor.onAction(.clear) { [weak self] in
            self?.handleCtrlC()
        }
        defaultEditor.onAction(.suspend) { [weak self] in
            self?.handleCtrlZ()
        }
        defaultEditor.onAction(.cycleThinkingLevel) { [weak self] in
            self?.cycleThinkingLevel()
        }
        defaultEditor.onAction(.cycleModelForward) { [weak self] in
            Task { @MainActor in
                await self?.cycleModel(direction: .forward)
            }
        }
        defaultEditor.onAction(.cycleModelBackward) { [weak self] in
            Task { @MainActor in
                await self?.cycleModel(direction: .backward)
            }
        }
        defaultEditor.onAction(.selectModel) { [weak self] in
            Task { @MainActor in
                self?.showModelSelector()
            }
        }
        defaultEditor.onAction(.expandTools) { [weak self] in
            Task { @MainActor in
                self?.toggleToolOutputExpansion()
            }
        }
        defaultEditor.onAction(.toggleThinking) { [weak self] in
            Task { @MainActor in
                self?.toggleThinkingBlockVisibility()
            }
        }
        defaultEditor.onAction(.externalEditor) { [weak self] in
            Task { await self?.openExternalEditor() }
        }
        defaultEditor.onAction(.copyMessage) { [weak self] in
            self?.handleCopyCommand(preferSelection: true)
        }
        defaultEditor.onAction(.followUp) { [weak self] in
            Task { @MainActor in
                await self?.handleAltEnter()
            }
        }
        defaultEditor.onAction(.dequeue) { [weak self] in
            Task { @MainActor in
                self?.handleDequeue()
            }
        }

        defaultEditor.onChange = { [weak self] text in
            guard let self else { return }
            let wasBash = self.isBashMode
            self.isBashMode = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!")
            if wasBash != self.isBashMode {
                Task { @MainActor in
                    self.updateEditorBorderColor()
                }
            }
        }

        defaultEditor.onPasteImage = { [weak self] in
            Task { @MainActor in
                self?.handleClipboardImagePaste()
            }
        }

        defaultEditor.onSubmit = { [weak self] text in
            Task { @MainActor in
                await self?.handleEditorSubmit(text)
            }
        }

        tui?.onDebug = { [weak self] in
            Task { @MainActor in
                self?.handleDebugCommand()
            }
        }

        Task { @MainActor in
            self.updateEditorBorderColor()
        }
    }

    func handleStartupSubmit(_ text: String) {
        editor?.setText(text)
        showStatus("Startup is still in progress")
    }

    private func drainManagedToolStatuses(_ statuses: ManagedToolStatuses) {
        for status in statuses.drain() {
            startupToolStatuses.append(status)
            showManagedToolStatus(status)
        }
    }

    func showManagedToolStatus(_ status: ToolStatus) {
        let message = status.type == .warning ? "Warning: \(status.message)" : status.message
        chatContainer.addChild(ThemedText({ theme.fg(status.type == .warning ? .warning : .dim, message) }, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    func renderStartupDiagnostics() {
        for status in startupToolStatuses { showManagedToolStatus(status) }
        startupToolStatuses.removeAll()
        for diagnostic in startupDiagnostics {
            switch diagnostic.type {
            case "error": showError(diagnostic.message)
            case "warning": showWarning(diagnostic.message)
            default: showStatus(diagnostic.message)
            }
        }
        startupDiagnostics.removeAll()
    }

    private func mountWorkingIndicator() {
        defaultEditor?.setWorkingStatusIndicator(nil)
        statusContainer?.clear()
        activeWorkingIndicatorEmbedded = false
        guard let indicator = transientStatusAnimation ?? (workingVisible ? loadingAnimation : nil) else { return }
        if let workingEditor = editor as? any WorkingStatusEditor, workingEditor.embedWorkingStatus {
            workingEditor.setWorkingStatusIndicator(indicator)
            activeWorkingIndicatorEmbedded = true
        } else {
            statusContainer?.addChild(indicator)
        }
    }

    private func setTransientStatus(_ message: String?) {
        transientStatusMessage = message
        transientStatusAnimation?.stop()
        transientStatusAnimation = message.flatMap { text in
            tui.map { tui in
                let embedded = (editor as? any WorkingStatusEditor)?.embedWorkingStatus == true
                let color: ((String) -> String)? = embedded ? { [weak self] value in
                    self?.editor?.borderColor(value) ?? theme.fg(.muted, value)
                } : nil
                return WorkingStatusIndicator(ui: tui, message: text, colorFn: color)
            }
        }
        mountWorkingIndicator()
        ui.requestRender()
    }

    private func clearWorkingIndicator() {
        defaultEditor?.setWorkingStatusIndicator(nil)
        (editor as? any WorkingStatusEditor)?.setWorkingStatusIndicator(nil)
        statusContainer?.clear()
        if !activeWorkingIndicatorEmbedded, tui?.mode == .mainScreen,
           session?.settingsManager.getClearOnShrink() == true {
            statusContainer?.addChild(Spacer(2))
        }
        activeWorkingIndicatorEmbedded = false
        if transientStatusAnimation != nil { mountWorkingIndicator() }
    }

    func subscribeToAgent() {
        guard let session else { return }
        unsubscribeFromAgent()
        unsubscribe = session.subscribe { [weak self] event in
            Task { @MainActor in
                self?.handleSessionEvent(event)
            }
        }
        let (events, continuation) = AsyncStream<any HookEvent>.makeStream()
        hookEventContinuation = continuation
        unsubscribeHookEvents = session.subscribeToHookEvents { event in
            continuation.yield(event)
        }
        hookEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handleHookEvent(event)
            }
        }
    }

    func unsubscribeFromAgent() {
        unsubscribe?()
        unsubscribe = nil
        unsubscribeHookEvents?()
        unsubscribeHookEvents = nil
        hookEventContinuation?.finish()
        hookEventContinuation = nil
        hookEventTask?.cancel()
        hookEventTask = nil
    }

    func handleHookEvent(_ event: any HookEvent) {
        guard let failure = event as? SessionCompactFailedEvent,
              !failure.aborted,
              let errorMessage = failure.errorMessage else { return }

        switch failure.reason {
        case .manual:
            guard failure.fromExtension else { return }
            showError(errorMessage)
        case .threshold, .overflow:
            if failure.willRetry {
                showStatus("\(errorMessage) (retrying)")
            } else {
                chatContainer.addChild(Spacer(1))
                chatContainer.addChild(ThemedText({ theme.fg(.error, errorMessage) }, paddingX: 1, paddingY: 0))
            }
        }
        footer?.invalidate()
        ui.requestRender()
    }

    @MainActor
    func handleSessionEvent(_ event: AgentSessionEvent) {
        if case .agent(.agentStart) = event { reportingManualCompaction = false }
        if case .agentSettled = event, reportingManualCompaction {
            programStatus.handleEvent(ProgramStatusInput.ignored)
        } else {
            programStatus.handleEvent(event)
        }
        footer?.invalidate()

        switch event {
        case .agent(let agentEvent):
            handleAgentEvent(agentEvent)
        case .nestedToolExecution:
            // v0.99.0: nested calls (codemode scripts, ctx.executeTool) are shown inside their
            // parent's row, not as their own rows (upstream interactive-mode.ts tool_execution_start).
            break
        case .entryAppended(let entry):
            // Entries committed by extension boundaries (turn_end / agent_before_settle).
            if entriesRenderedByBoundaryCompaction.remove(entry.id) != nil { break }
            switch entry {
            case .usage(let usageEntry) where usageEntry.kind == "cache_warm":
                addCacheWarmingUsage(usageEntry)
                scheduleRender()
            case .customMessage(let entry) where entry.display:
                addMessageToChat(makeHookAgentMessage(HookMessage(customType: entry.customType, content: entry.content, display: entry.display, details: entry.details, timestamp: 0)))
                scheduleRender()
            case .custom(let entry):
                if let renderer = session?.hookRunner?.getEntryRenderer(entry.customType) {
                    let component = CustomEntryComponent(entry: entry, renderer: renderer, outputPad: tuiConfiguration.outputPad)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                    scheduleRender()
                }
            case .compaction(let compaction):
                guard let session else { break }
                let entries = session.sessionManager.buildContextEntries()
                guard entries.first?.id == compaction.id else { break }
                let branch = session.sessionManager.getBranch()
                guard let compactionIndex = branch.firstIndex(where: { $0.id == compaction.id }) else { break }
                let afterIDs = Set(branch.dropFirst(compactionIndex + 1).map(\.id))
                let retained = Array(entries.dropFirst())
                let before = retained.filter { !afterIDs.contains($0.id) }
                let after = retained.filter { afterIDs.contains($0.id) }
                renderInitialMessages(entries: before + [entry] + after)
                entriesRenderedByBoundaryCompaction.formUnion(afterIDs)
                footer?.invalidate()
            default:
                break
            }
        case .agentSettled:
            // Hook follow-ups and persisted display-only entries settle after agent_end.
            renderInitialMessages()
        case .autoCompactionStart:
            setTransientStatus("Compacting")
        case .autoCompactionEnd(let result, let aborted, _, _):
            setTransientStatus(nil)
            if aborted {
                showStatus("Auto-compaction cancelled")
            } else if let result {
                let entries = session.map { interactiveContextEntries($0.sessionManager) } ?? []
                guard let first = entries.first, case .compaction = first else {
                    showError("Completed compaction is missing from the session context")
                    return
                }
                renderInitialMessages(entries: Array(entries.dropFirst()))
                let compactionMessage = CompactionSummaryMessage(summary: result.summary, tokensBefore: result.tokensBefore, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
                let component = CompactionSummaryMessageComponent(message: compactionMessage, outputPad: tuiConfiguration.outputPad)
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                if let usage = result.usage { addSummaryCostNotice(usage) }
                footer?.invalidate()
                if session?.isStreaming == true { mountWorkingIndicator() }
                showStatus("Compaction completed")
            }
        case .autoRetryStart(let attempt, let maxAttempts, _, let errorMessage):
            setTransientStatus("Retrying (\(attempt)/\(maxAttempts)): \(errorMessage)")
        case .autoRetryEnd(let success, let attempt, let finalError):
            setTransientStatus(nil)
            if !success {
                showError("Retry failed after \(attempt) attempts: \(finalError ?? "Unknown error")")
            }
        }
    }

    /// The `/bug` hint is shown at most once per session so error output stays readable.
    @MainActor
    private func maybeSuggestBugReport(_ message: AssistantMessage, sessionId: String) {
        let tracker = bugReportHints
        Task { @MainActor [weak self] in
            guard await tracker.shouldSuggest(sessionId: sessionId, message: message), let self else { return }
            self.chatContainer.addChild(ThemedText({ theme.fg(.muted, "If this looks like a pi bug, /bug sends a report to the developers.") }, paddingX: 1, paddingY: 0))
            self.scheduleRender()
        }
    }

    @MainActor
    func handleAgentEvent(_ event: AgentEvent) {
        guard let session, let statusContainer, let tui else { return }

        switch event {
        case .agentStart:
            pendingTools.removeAll()

        case .turnStart:
            if session.settingsManager.getShowTerminalProgress() { tui.terminal.setProgress(true) }
            guard loadingAnimation == nil else { return }
            statusContainer.clear()
            loadingAnimation = makeWorkingIndicator()
            if workingVisible { mountWorkingIndicator() }
            scheduleRender()

        case .messageStart(let message):
            if message.role == "user" {
                let text = extractUserMessageText(message)
                if let idx = pendingSteeringMessages.firstIndex(of: text) {
                    pendingSteeringMessages.remove(at: idx)
                } else if let idx = pendingFollowUpMessages.firstIndex(of: text) {
                    pendingFollowUpMessages.remove(at: idx)
                }
                addMessageToChat(message)
                editor?.setText("")
                updatePendingMessagesDisplay()
                scheduleRender()
            } else if case .assistant(let assistant) = message {
                streamingComponent = AssistantMessageComponent(
                    hideThinkingBlock: hideThinkingBlock,
                    hiddenThinkingLabel: hiddenThinkingLabel,
                    markdownConfiguration: tuiConfiguration,
                    isStreaming: true
                )
                streamingMessage = assistant
                if let streamingComponent {
                    chatContainer.addChild(streamingComponent)
                    streamingComponent.updateContent(assistant)
                }
                scheduleRender()
            } else if message.role == "hookMessage" {
                addMessageToChat(message)
                scheduleRender()
            }

        case .messageUpdate(let message, _):
            if case .assistant(let assistant) = message {
                streamingMessage = assistant
                streamingComponent?.updateContent(assistant)
                for block in assistant.content {
                    if case .toolCall(let call) = block {
                        if pendingTools[call.id] == nil {
                            let component = ToolExecutionComponent(
                                toolName: call.name,
                                toolCallId: call.id,
                                args: toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON),
                                options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages(), imageWidthCells: session.settingsManager.getImageWidthCells(), outputPad: tuiConfiguration.outputPad),
                                renderers: resolvedToolRenderers(call.name, session: session, fallback: customTools[call.name]?.tool),
                                ui: tui
                            )
                            component.setExpanded(toolOutputExpanded)
                            chatContainer.addChild(component)
                            pendingTools[call.id] = component
                        } else {
                            pendingTools[call.id]?.updateArgs(toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON))
                        }
                    }
                }
                scheduleRender()
            }

        case .messageEnd(let message):
            if case .assistant(let assistant) = message {
                streamingComponent?.setStreaming(false)
                streamingComponent?.updateContent(assistant)
                if assistant.stopReason == .aborted || assistant.stopReason == .error {
                    let errorMessage = assistant.errorMessage ?? "Request failed"
                    for component in pendingTools.values {
                        let result = ToolResultMessage(toolCallId: "", toolName: "", content: [.text(TextContent(text: errorMessage))], details: nil, isError: true)
                        component.updateResult(result, isPartial: false)
                    }
                    pendingTools.removeAll()
                    maybeSuggestBugReport(assistant, sessionId: session.sessionManager.getSessionId())
                } else {
                    for component in pendingTools.values {
                        component.setArgsComplete()
                    }
                    maybeShowAssistantDiagnostics(assistant)
                }
                streamingComponent = nil
                streamingMessage = nil
            }
            scheduleRender()

        case .toolExecutionStart(let toolCallId, let toolName, let args):
            if pendingTools[toolCallId] == nil {
                let component = ToolExecutionComponent(
                    toolName: toolName,
                    toolCallId: toolCallId,
                    args: args,
                    options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages(), imageWidthCells: session.settingsManager.getImageWidthCells(), outputPad: tuiConfiguration.outputPad),
                    renderers: resolvedToolRenderers(toolName, session: session, fallback: customTools[toolName]?.tool),
                    ui: tui
                )
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                pendingTools[toolCallId] = component
            }

            pendingTools[toolCallId]?.updateArgs(args)
            pendingTools[toolCallId]?.markExecutionStarted()
            pendingTools[toolCallId]?.setArgsComplete()
            if toolName == "bash" { footer?.setBashToolRunning(true) }
            scheduleRender()

        case .toolExecutionUpdate(let toolCallId, let toolName, _, let partialResult):
            if let component = pendingTools[toolCallId] {
                let result = ToolResultMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    content: partialResult.content,
                    details: partialResult.details,
                    isError: false
                )
                component.updateResult(result, isPartial: true)
                scheduleRender()
            }

        case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError, let durationMs):
            if let component = pendingTools[toolCallId] {
                let message = ToolResultMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    content: result.content,
                    details: result.details,
                    isError: isError,
                    durationMs: durationMs
                )
                component.updateResult(message, isPartial: false)
                pendingTools.removeValue(forKey: toolCallId)
                if toolName == "bash" {
                    footer?.setBashToolRunning(false)
                }
                scheduleRender()
            }

        case .agentEnd:
            loadingAnimation?.stop()
            loadingAnimation = nil
            clearWorkingIndicator()
            tui.terminal.setProgress(false)
            if let streamingComponent {
                chatContainer.removeChild(streamingComponent)
                self.streamingComponent = nil
                streamingMessage = nil
            }
            pendingTools.removeAll()
            footer?.setBashToolRunning(false)
            emitOsc133("D") // command finished
            emitOsc133("A") // prompt start — ready for next input
            scheduleRender()

        case .turnEnd:
            break
        }
    }

    @MainActor
    func renderInitialMessages(entries suppliedEntries: [SessionEntry]? = nil) {
        altScreenRenderer?.resetTextSelection()
        guard let session, let tui else { return }
        let resourceOptions = pendingResourceDisplayOptions
        pendingResourceDisplayOptions = nil
        chatContainer.clear()
        pendingTools.removeAll()
        if let resourceOptions {
            showLoadedResources(resourceOptions)
        }
        var toolCalls: [String: (name: String, args: [String: AnyCodable])] = [:]

        let entries = suppliedEntries ?? interactiveContextEntries(session.sessionManager)
        let thinkingNotices = thinkingDropNoticesByEntryID(session.sessionManager.getBranch())
        let cacheMisses = settingsManagerCacheMisses(session, entries: entries)
        for entry in entries {
            switch entry {
            case .message(let messageEntry):
                let message = messageEntry.message
                switch message {
            case .assistant(let assistant):
                for block in assistant.content {
                    if case .toolCall(let call) = block {
                        toolCalls[call.id] = (name: call.name, args: toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON))
                    }
                }
                addMessageToChat(message)
                if assistant.stopReason != .aborted && assistant.stopReason != .error,
                   let notice = thinkingNotices[messageEntry.id] { addThinkingDropNotice(notice) }
            case .toolResult(let toolResult):
                let toolInfo = toolCalls[toolResult.toolCallId]
                let component = ToolExecutionComponent(
                    toolName: toolInfo?.name ?? toolResult.toolName,
                    toolCallId: toolResult.toolCallId,
                    args: toolInfo?.args ?? [:],
                    options: ToolExecutionOptions(showImages: session.settingsManager.getShowImages(), imageWidthCells: session.settingsManager.getImageWidthCells(), outputPad: tuiConfiguration.outputPad),
                    renderers: resolvedToolRenderers(toolInfo?.name ?? toolResult.toolName, session: session,
                        fallback: customTools[toolInfo?.name ?? toolResult.toolName]?.tool),
                    ui: tui
                )
                component.setExpanded(toolOutputExpanded)
                component.updateResult(toolResult, isPartial: false)
                chatContainer.addChild(component)
            default:
                addMessageToChat(message)
            }
                if let miss = cacheMisses[messageEntry.id] {
                    chatContainer.addChild(ThemedText({ theme.fg(.warning, formatCacheMissNotice(miss)) }, paddingX: 1, paddingY: 0))
                }
            case .compaction(let entry):
                let component = CompactionSummaryMessageComponent(message: CompactionSummaryMessage(summary: entry.summary, tokensBefore: entry.tokensBefore, timestamp: 0), outputPad: tuiConfiguration.outputPad)
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                if let usage = entry.usage { addSummaryCostNotice(usage) }
            case .branchSummary(let entry):
                let component = BranchSummaryMessageComponent(message: BranchSummaryMessage(summary: entry.summary, fromId: entry.fromId, timestamp: 0), outputPad: tuiConfiguration.outputPad)
                component.setExpanded(toolOutputExpanded)
                chatContainer.addChild(component)
                if let usage = entry.usage { addSummaryCostNotice(usage, branch: true) }
            case .customMessage(let entry):
                addMessageToChat(makeHookAgentMessage(HookMessage(customType: entry.customType, content: entry.content, display: entry.display, details: entry.details, timestamp: 0)))
            case .custom(let entry):
                if let renderer = session.hookRunner?.getEntryRenderer(entry.customType) {
                    let component = CustomEntryComponent(entry: entry, renderer: renderer, outputPad: tuiConfiguration.outputPad)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            case .usage(let entry) where entry.kind == "cache_warm":
                addCacheWarmingUsage(entry)
            default:
                break
            }
        }

        let compactionCount = session.sessionManager.getEntries().filter { if case .compaction = $0 { return true } else { return false } }.count
        if compactionCount > 0 {
            let times = compactionCount == 1 ? "1 time" : "\(compactionCount) times"
            showStatus("Session compacted \(times)")
        }

        scheduleRender()
    }

    @MainActor
    func addSummaryCostNotice(_ usage: Usage, branch: Bool = false) {
        guard session?.settingsManager.getShowCacheMissNotices() == true else { return }
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.warning, summaryCostNotice(usage: usage, branch: branch)) }, paddingX: 1, paddingY: 0))
    }

    @MainActor
    func addCacheWarmingUsage(_ entry: UsageEntry) {
        guard session?.settingsManager.getShowCacheMissNotices() == true else { return }
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.dim, formatCacheWarmingUsage(entry)) }, paddingX: 1, paddingY: 0))
    }

    func maybeShowAssistantDiagnostics(_ message: AssistantMessage) {
        guard session?.settingsManager.getShowCacheMissNotices() == true else { return }
        guard let notice = session?.sessionManager.newThinkingDropNotice(for: message) else { return }
        addThinkingDropNotice(notice)
    }

    private func addThinkingDropNotice(_ notice: ThinkingDropNotice) {
        guard session?.settingsManager.getShowCacheMissNotices() == true else { return }
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.warning, thinkingDropNoticeText(notice)) }, paddingX: 1, paddingY: 0))
    }

    @MainActor
    private func addMessageToChat(_ message: AgentMessage) {
        switch message {
        case .system:
            // System messages carry the prompt and tool state; they have no chat row.
            break
        case .user(let user):
            let text = extractUserContentText(user.content)
            chatContainer.addChild(UserMessageComponent(text: text, markdownConfiguration: tuiConfiguration))
        case .assistant(let assistant):
            let component = AssistantMessageComponent(
                message: assistant,
                hideThinkingBlock: hideThinkingBlock,
                hiddenThinkingLabel: hiddenThinkingLabel,
                markdownConfiguration: tuiConfiguration
            )
            chatContainer.addChild(component)
        case .toolResult:
            break
        case .custom(let custom):
            switch custom.role {
            case "bashExecution":
                if let bash = decodeBashExecutionMessage(custom) {
                    if let tui {
                        let component = BashExecutionComponent(command: bash.command, ui: tui, excludeFromContext: bash.excludeFromContext ?? false, outputPad: tuiConfiguration.outputPad)
                        component.appendOutput(bash.output)
                        let truncation = bash.truncated ? truncateTail(bash.output) : nil
                        component.setComplete(exitCode: bash.exitCode, cancelled: bash.cancelled, truncationResult: truncation, fullOutputPath: bash.fullOutputPath)
                        component.setExpanded(toolOutputExpanded)
                        chatContainer.addChild(component)
                    }
                }
            case "branchSummary":
                if let summary = decodeBranchSummaryMessage(custom) {
                    let component = BranchSummaryMessageComponent(message: summary, outputPad: tuiConfiguration.outputPad)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            case "compactionSummary":
                if let summary = decodeCompactionSummaryMessage(custom) {
                    let component = CompactionSummaryMessageComponent(message: summary, outputPad: tuiConfiguration.outputPad)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            case "hookMessage":
                if let hook = decodeHookMessage(custom), hook.display {
                    let renderer = session?.hookRunner?.getMessageRenderer(hook.customType)
                    let component = HookMessageComponent(message: hook, customRenderer: renderer, outputPad: tuiConfiguration.outputPad)
                    component.setExpanded(toolOutputExpanded)
                    chatContainer.addChild(component)
                }
            default:
                break
            }
        }
    }

    private func scheduleRender(force: Bool = false) {
        if let tui {
            tui.requestRender(force: force)
        } else {
            ui.requestRender()
        }
    }

    private func formatDisplayPath(_ path: String) -> String {
        let home = getHomeDir()
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : "\(home)/"
        if path.hasPrefix(prefix) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func getShortPath(_ fullPath: String, source: String) -> String {
        if source.hasPrefix("npm:") {
            if let range = fullPath.range(of: "/node_modules/") {
                let remainder = fullPath[range.upperBound...]
                let parts = remainder.split(separator: "/")
                if parts.isEmpty { return formatDisplayPath(fullPath) }
                var index = 1
                if parts[0].hasPrefix("@") {
                    guard parts.count > 1 else { return formatDisplayPath(fullPath) }
                    index = 2
                }
                if parts.count > index {
                    return parts[index...].joined(separator: "/")
                }
                return ""
            }
        }

        if source.hasPrefix("git:"), let range = fullPath.range(of: "/git/") {
            let remainder = fullPath[range.upperBound...]
            let parts = remainder.split(separator: "/")
            guard parts.count >= 2 else { return formatDisplayPath(fullPath) }
            let sourceValue = source.dropFirst(4)
            let repoSpec = sourceValue.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let sourceParts = repoSpec.split(separator: "/")
            if let host = sourceParts.first, parts.first == host {
                let repoCount = max(0, sourceParts.count - 1)
                let startIndex = 1 + repoCount
                if parts.count > startIndex {
                    return parts[startIndex...].joined(separator: "/")
                }
                return ""
            }
        }

        return formatDisplayPath(fullPath)
    }

    private func getDisplaySourceInfo(source: String, scope: String) -> (label: String, scopeLabel: String?) {
        if source == "local" {
            if scope == "user" {
                return (label: "user", scopeLabel: nil)
            }
            if scope == "project" {
                return (label: "project", scopeLabel: nil)
            }
            if scope == "temporary" {
                return (label: "path", scopeLabel: "temp")
            }
            return (label: "path", scopeLabel: nil)
        }

        if source == "cli" {
            return (label: "path", scopeLabel: scope == "temporary" ? "temp" : nil)
        }

        let scopeLabel: String?
        switch scope {
        case "user":
            scopeLabel = "user"
        case "project":
            scopeLabel = "project"
        case "temporary":
            scopeLabel = "temp"
        default:
            scopeLabel = nil
        }
        return (label: source, scopeLabel: scopeLabel)
    }

    private func getScopeGroup(source: String, scope: String) -> String {
        if source == "cli" || scope == "temporary" { return "path" }
        if scope == "user" { return "user" }
        if scope == "project" { return "project" }
        return "path"
    }

    private func isPackageSource(_ source: String) -> Bool {
        source.hasPrefix("npm:") || source.hasPrefix("git:")
    }

    private func buildScopeGroups(_ paths: [String], _ metadata: [String: PathMetadata]) -> [ScopeGroup] {
        var groups: [String: ScopeGroup] = [
            "user": ScopeGroup(scope: "user", paths: [], packages: [:]),
            "project": ScopeGroup(scope: "project", paths: [], packages: [:]),
            "path": ScopeGroup(scope: "path", paths: [], packages: [:]),
        ]

        for path in paths {
            let meta = findMetadata(path, metadata)
            let source = meta?.source ?? "local"
            let scope = meta?.scope ?? "project"
            let groupKey = getScopeGroup(source: source, scope: scope)
            var group = groups[groupKey] ?? ScopeGroup(scope: groupKey, paths: [], packages: [:])

            if isPackageSource(source) {
                var list = group.packages[source] ?? []
                list.append(path)
                group.packages[source] = list
            } else {
                group.paths.append(path)
            }

            groups[groupKey] = group
        }

        let ordered = ["user", "project", "path"].compactMap { groups[$0] }
        return ordered.filter { !$0.paths.isEmpty || !$0.packages.isEmpty }
    }

    private func formatScopeGroups(
        _ groups: [ScopeGroup],
        formatPath: (String) -> String,
        formatPackagePath: (String, String) -> String
    ) -> String {
        var lines: [String] = []
        for group in groups {
            lines.append("  \(theme.fg(.accent, group.scope))")

            let sortedPaths = group.paths.sorted { $0.localizedCompare($1) == .orderedAscending }
            for path in sortedPaths {
                lines.append(theme.fg(.dim, "    \(formatPath(path))"))
            }

            let sortedPackages = group.packages.keys.sorted { $0.localizedCompare($1) == .orderedAscending }
            for source in sortedPackages {
                lines.append("    \(theme.fg(.mdLink, source))")
                let paths = (group.packages[source] ?? []).sorted { $0.localizedCompare($1) == .orderedAscending }
                for path in paths {
                    lines.append(theme.fg(.dim, "      \(formatPackagePath(path, source))"))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func findMetadata(_ path: String, _ metadata: [String: PathMetadata]) -> PathMetadata? {
        if let exact = metadata[path] { return exact }

        var current = path
        while let range = current.range(of: "/", options: .backwards) {
            current = String(current[..<range.lowerBound])
            if let parent = metadata[current] { return parent }
            if current.isEmpty { break }
        }

        return nil
    }

    private func formatPathWithSource(_ path: String, _ metadata: [String: PathMetadata]) -> String {
        if let meta = findMetadata(path, metadata) {
            let shortPath = getShortPath(path, source: meta.source)
            let info = getDisplaySourceInfo(source: meta.source, scope: meta.scope)
            let labelText = info.scopeLabel == nil ? info.label : "\(info.label) (\(info.scopeLabel ?? ""))"
            return "\(labelText) \(shortPath)"
        }
        return formatDisplayPath(path)
    }

    private func formatDiagnostics(_ diagnostics: [ResourceDiagnostic], _ metadata: [String: PathMetadata]) -> String {
        var lines: [String] = []
        var collisions: [String: [ResourceDiagnostic]] = [:]
        var others: [ResourceDiagnostic] = []

        for diagnostic in diagnostics {
            if diagnostic.type == "collision", let collision = diagnostic.collision {
                collisions[collision.name, default: []].append(diagnostic)
            } else {
                others.append(diagnostic)
            }
        }

        for name in collisions.keys.sorted() {
            guard let collisionList = collisions[name], let first = collisionList.first?.collision else { continue }
            lines.append(theme.fg(.warning, "  \"\(name)\" collision:"))
            lines.append(theme.fg(.dim, "    \(theme.fg(.success, "✓")) \(formatPathWithSource(first.winnerPath, metadata))"))
            for diagnostic in collisionList {
                if let collision = diagnostic.collision {
                    lines.append(theme.fg(.dim, "    \(theme.fg(.warning, "✗")) \(formatPathWithSource(collision.loserPath, metadata)) (skipped)"))
                }
            }
        }

        for diagnostic in others {
            let color: ThemeColor = diagnostic.type == "error" ? .error : .warning
            if let path = diagnostic.path {
                let sourceInfo = formatPathWithSource(path, metadata)
                lines.append(theme.fg(color, "  \(sourceInfo)"))
                lines.append(theme.fg(color, "    \(diagnostic.message)"))
            } else {
                lines.append(theme.fg(color, "  \(diagnostic.message)"))
            }
        }

        return lines.joined(separator: "\n")
    }

    func showLoadedResources(_ options: ResourceDisplayOptions) {
        loadedResourcesContainer.clear()
        guard let session else { return }
        let settingsManager = session.settingsManager
        guard options.force || settingsManager.getQuietStartup().showsStartupDetails(verbose: verboseStartup) else { return }

        let metadata = session.resourceLoader.getPathMetadata()
        let expanded = verboseStartup || toolOutputExpanded
        func compactList(_ labels: [String], sort: Bool = true) -> String {
            let labels = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return theme.fg(.dim, "  " + (sort ? labels.sorted() : labels).joined(separator: ", "))
        }
        func addSection(_ name: String, collapsed: @escaping () -> String, expandedBody: @escaping () -> String) {
            loadedResourcesContainer.addChild(ExpandableText(
                collapsed: { "\(theme.fg(.mdHeading, "[\(name)]"))\n\(collapsed())" },
                expanded: { "\(theme.fg(.mdHeading, "[\(name)]"))\n\(expandedBody())" },
                isExpanded: expanded
            ))
            loadedResourcesContainer.addChild(Spacer(1))
        }
        func addDiagnostics(_ name: String, _ diagnostics: [ResourceDiagnostic], diagnosticMetadata: [String: PathMetadata]? = nil) {
            guard !diagnostics.isEmpty else { return }
            let sources = diagnosticMetadata ?? metadata
            loadedResourcesContainer.addChild(ThemedText({ [weak self] in
                "\(theme.fg(.warning, "[\(name)]"))\n\(self?.formatDiagnostics(diagnostics, sources) ?? "")"
            }, paddingX: 0, paddingY: 0))
            loadedResourcesContainer.addChild(Spacer(1))
        }

        let contextPaths = session.resourceLoader.getSystemPromptSource().map { [$0.path] } ?? []
        let contextFiles = contextPaths + session.resourceLoader.getAppendSystemPromptSources().map { $0.path }
            + session.resourceLoader.getAgentsFiles().map { $0.path }
        if !contextFiles.isEmpty {
            loadedResourcesContainer.addChild(Spacer(1))
            let paths = contextFiles
            let cwd = session.sessionManager.getCwd()
            let labels = paths.map { path in
                path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : formatDisplayPath(path)
            }
            addSection("Context", collapsed: { compactList(labels, sort: false) }, expandedBody: { [weak self] in
                paths.map { theme.fg(.dim, "  \(self?.formatDisplayPath($0) ?? $0)") }.joined(separator: "\n")
            })
        }

        let skillResult = session.resourceLoader.getSkills()
        if !skillResult.skills.isEmpty {
            let groups = buildScopeGroups(skillResult.skills.map { $0.filePath }, metadata)
            let names = skillResult.skills.map { $0.name }
            addSection("Skills", collapsed: { compactList(names) }, expandedBody: { [weak self] in
                guard let self else { return "" }
                return formatScopeGroups(groups, formatPath: { self.formatDisplayPath($0) },
                                         formatPackagePath: { self.getShortPath($0, source: $1) })
            })
        }

        let templates = session.promptTemplates
        if !templates.isEmpty {
            let groups = buildScopeGroups(templates.map { $0.filePath }, metadata)
            let templateByPath = Dictionary(uniqueKeysWithValues: templates.map { ($0.filePath, $0) })
            let names = templates.map { "/\($0.name)" }
            addSection("Prompts", collapsed: { compactList(names) }, expandedBody: { [weak self] in
                guard let self else { return "" }
                return formatScopeGroups(groups, formatPath: { path in
                    templateByPath[path].map { "/\($0.name)" } ?? self.formatDisplayPath(path)
                }, formatPackagePath: { path, _ in
                    templateByPath[path].map { "/\($0.name)" } ?? self.formatDisplayPath(path)
                })
            })
        }

        if !options.extensionPaths.isEmpty {
            let paths = options.extensionPaths
            let groups = buildScopeGroups(paths, metadata)
            let labels = compactExtensionLabels(paths, metadata)
            addSection("Extensions", collapsed: { compactList(labels) }, expandedBody: { [weak self] in
                guard let self else { return "" }
                return formatScopeGroups(groups, formatPath: { self.formatExtensionDisplayPath($0) },
                                         formatPackagePath: { self.formatExtensionDisplayPath(self.getShortPath($0, source: $1)) })
            })
        }

        var skillMetadata: [String: PathMetadata] = [:]
        for skill in skillResult.skills {
            let info = skill.sourceInfo
            skillMetadata[skill.filePath] = PathMetadata(
                source: info.source, scope: info.scope, origin: info.origin ?? "top-level", baseDir: info.baseDir
            )
        }
        addDiagnostics("Skill conflicts", skillResult.diagnostics, diagnosticMetadata: skillMetadata)
        addDiagnostics("Prompt conflicts", session.resourceLoader.getPrompts().diagnostics)
        addDiagnostics("Extension issues", session.resourceLoader.getExtensions().diagnostics)
        // Upstream v0.99.1 removes the Themes list and retains theme diagnostics.
        addDiagnostics("Theme conflicts", session.resourceLoader.getThemes().diagnostics)
    }

    private func formatExtensionDisplayPath(_ path: String) -> String {
        let display = formatDisplayPath(path)
        for suffix in ["/index.ts", "/index.js"] where display.hasSuffix(suffix) {
            return String(display.dropLast(suffix.count))
        }
        return display
    }

    private func compactExtensionLabels(_ paths: [String], _ metadata: [String: PathMetadata]) -> [String] {
        let localPaths = paths.filter { !isPackageSource(findMetadata($0, metadata)?.source ?? "local") }
        let segments = localPaths.map {
            formatExtensionDisplayPath($0).split(separator: "/").map(String.init).filter { $0 != "~" }
        }
        return paths.map { path in
            if let meta = findMetadata(path, metadata), isPackageSource(meta.source) {
                var source = meta.source
                if source.hasPrefix("npm:") { source = String(source.dropFirst(4)) }
                else if source.hasPrefix("git:") {
                    source = String(source.dropFirst(4)).split(separator: "@", maxSplits: 1).first.map(String.init) ?? source
                }
                let short = getShortPath(path, source: meta.source)
                let packagePath = short.hasPrefix("extensions/") ? String(short.dropFirst(11)) : short
                if ["index.ts", "index.js"].contains(URL(fileURLWithPath: packagePath).lastPathComponent) {
                    let directory = (packagePath as NSString).deletingLastPathComponent
                    return directory.isEmpty || directory == "." ? source : "\(source):\(directory)"
                }
                return "\(source):\(packagePath)"
            }
            guard let index = localPaths.firstIndex(of: path), !segments[index].isEmpty else {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            for count in 1...segments[index].count {
                let candidate = segments[index].suffix(count).joined(separator: "/")
                if segments.enumerated().allSatisfy({ $0.offset == index || $0.element.suffix(count).joined(separator: "/") != candidate }) {
                    return candidate
                }
            }
            return segments[index].joined(separator: "/")
        }
    }

    private func extractUserMessageText(_ message: AgentMessage) -> String {
        switch message {
        case .user(let user):
            return extractUserContentText(user.content)
        default:
            return ""
        }
    }

    private func extractUserContentText(_ content: UserContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let text) = block {
                    return text.text
                }
                return nil
            }.joined()
        }
    }

    @MainActor
    private func updatePendingMessagesDisplay() {
        guard let pendingMessagesContainer else { return }
        pendingMessagesContainer.clear()

        if pendingSteeringMessages.isEmpty && pendingFollowUpMessages.isEmpty && pendingBashComponents.isEmpty {
            return
        }

        let hasQueuedMessages = !pendingSteeringMessages.isEmpty || !pendingFollowUpMessages.isEmpty
        pendingMessagesContainer.addChild(Spacer(1))
        for message in pendingSteeringMessages {
            let text = theme.fg(.dim, "Steering: \(message)")
            pendingMessagesContainer.addChild(TruncatedText(text, paddingX: 1, paddingY: 0))
        }
        for message in pendingFollowUpMessages {
            let text = theme.fg(.dim, "Follow-up: \(message)")
            pendingMessagesContainer.addChild(TruncatedText(text, paddingX: 1, paddingY: 0))
        }
        for component in pendingBashComponents {
            pendingMessagesContainer.addChild(component)
        }
        if hasQueuedMessages {
            let dequeueHint = getAppKeyDisplay(.dequeue)
            let hintText = theme.fg(.dim, "-> \(dequeueHint) to edit all queued messages")
            pendingMessagesContainer.addChild(TruncatedText(hintText, paddingX: 1, paddingY: 0))
        }
    }

    @MainActor
    private func flushPendingBashComponents() {
        guard let session else { return }
        for component in pendingBashComponents {
            pendingMessagesContainer?.removeChild(component)
            chatContainer.addChild(component)
        }
        pendingBashComponents.removeAll()
        updatePendingMessagesDisplay()

        for message in pendingBashMessages {
            let agentMessage = makeBashExecutionAgentMessage(message)
            session.agent.appendMessage(agentMessage)
            _ = session.sessionManager.appendMessage(agentMessage)
        }
        pendingBashMessages.removeAll()
    }

    @MainActor
    private func updateEditorBorderColor() {
        guard let editor, let session else { return }
        if isBashMode {
            editor.borderColor = { @Sendable text in
                theme.getBashModeBorderColor()(text)
            }
        } else {
            let level = session.agent.state.thinkingLevel.rawValue
            editor.borderColor = { @Sendable text in
                theme.getThinkingBorderColor(level)(text)
            }
        }
        loadingAnimation?.invalidate()
    }

    @MainActor
    private func handleEscape() {
        if session?.isCompacting == true {
            Task { await session?.abort() }
            return
        }
        if loadingAnimation != nil {
            _ = restoreQueuedMessagesToEditor(abort: true)
            return
        }

        if bashAbort != nil {
            bashAbort?.cancel()
            return
        }

        if isBashMode {
            editor?.setText("")
            isBashMode = false
            updateEditorBorderColor()
            return
        }

        if editor?.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            let now = Date().timeIntervalSince1970
            if now - lastEscapeTime < 0.5 {
                if session?.settingsManager.getDoubleEscapeAction() == "tree" {
                    showTreeSelector()
                } else {
                    showUserMessageSelector()
                }
                lastEscapeTime = 0
            } else {
                lastEscapeTime = now
            }
        }
    }

    @MainActor
    private func handleCtrlC() {
        let now = Date().timeIntervalSince1970
        if now - lastSigintTime < 0.5 {
            requestShutdown()
            return
        }
        lastSigintTime = now
        editor?.setText("")
        scheduleRender()
    }

    @MainActor
    private func handleCtrlD() {
        if editor?.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            requestShutdown()
        }
    }

    @MainActor
    private func handleCtrlZ() {
        guard let tui else { return }
        let signalSource = DispatchSource.makeSignalSource(signal: SIGCONT, queue: .main)
        signal(SIGCONT, SIG_IGN)
        signalSource.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tui?.start()
                self?.tui?.requestRender(force: true)
            }
            signalSource.cancel()
            self?.sigcontSource = nil
        }
        signalSource.resume()
        sigcontSource = signalSource

        tui.stop()
        kill(getpid(), SIGTSTP)
    }

    @MainActor
    private func requestShutdown(fromSignal: Bool = false) {
        Task { @MainActor in
            await performShutdown(fromSignal: fromSignal)
        }
    }

    @MainActor
    func performShutdown(fromSignal: Bool = false) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        mcpUi?.cancelManager()
        loadingAnimation?.stop()
        loadingAnimation = nil
        clearWorkingIndicator()
        if !fromSignal { tui?.terminal.setProgress(false) }
        unregisterShutdownSignalHandlers()

        if fromSignal {
            killTrackedDetachedChildren()
            await emitSessionShutdownEvents()
            guard !hasExitedForTerminalError else { return }
            tui?.terminal.setProgress(false)
            themeController?.dispose()
        }

        unsubscribeFromAgent()
        footerBranchUnsubscribe?()
        footerBranchUnsubscribe = nil
        footerDataProvider?.dispose()
        footerDataProvider = nil
        backgroundCatalogRefreshTask?.cancel()
        backgroundCatalogRefreshTask = nil
        // Consume delayed terminal capability replies while input is still in raw mode. This
        // prevents them from reaching the parent shell after terminal state is restored.
        tui?.terminal.drainInput(maxMs: 100, idleMs: 10)
        if !fromSignal { themeController?.dispose() }
        stopInteractiveTui()
        guard !hasExitedForTerminalError else { return }

        if !fromSignal {
            await emitSessionShutdownEvents()
        }
        guard !hasExitedForTerminalError else { return }
        tui?.setIOErrorHandler(nil)

        if let continuation = exitContinuation {
            exitContinuation = nil
            continuation.resume()
        }
    }

    /// Install this before renderer startup, which can write to the terminal.
    func registerTerminalIOErrorHandler() {
        #if canImport(Darwin)
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        #endif
        tui?.setIOErrorHandler { [weak self] error in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleTerminalIOError(error) }
            } else {
                Task { @MainActor [weak self] in self?.handleTerminalIOError(error) }
            }
        }
    }

    func handleTerminalIOError(_ error: TerminalIOError) {
        guard !hasExitedForTerminalError else { return }
        // Loss must also end a normal shutdown that is waiting for extension cleanup.
        if error.isTerminalLoss {
            emergencyTerminalExit()
            return
        }
        if isShuttingDown {
            finishTerminalErrorExit(1)
            return
        }
        isShuttingDown = true
        unregisterShutdownSignalHandlers()
        killTrackedDetachedChildren()
        themeController?.dispose()
        tui?.stop()
        guard !hasExitedForTerminalError else { return }
        tui?.setIOErrorHandler(nil)
        let failure = InteractiveTerminalFailure(error: error)
        writeTerminalDiagnostic("\(APP_NAME) exiting due to terminal I/O error: \(failure.localizedDescription)\n")
        guard !hasExitedForTerminalError else { return }
        _ = crashLog.append(kind: .uncaughtException, error: failure,
                            sessionFile: session?.sessionManager.getSessionFile(),
                            cwd: session?.sessionManager.getCwd() ?? FileManager.default.currentDirectoryPath,
                            version: version)
        finishTerminalErrorExit(1)
    }

    private func emergencyTerminalExit() {
        isShuttingDown = true
        unregisterShutdownSignalHandlers()
        tui?.setIOErrorHandler(nil)
        killTrackedDetachedChildren()
        finishTerminalErrorExit(129)
    }

    private func finishTerminalErrorExit(_ status: Int32) {
        hasExitedForTerminalError = true
        tui?.setIOErrorHandler(nil)
        exitProcess(status)
    }

    private func writeTerminalDiagnostic(_ message: String) {
        Data(message.utf8).withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(STDERR_FILENO, base.advanced(by: offset), bytes.count - offset)
                let code = errno
                if count > 0 { offset += count; continue }
                if count < 0 && code == EINTR { continue }
                let error = TerminalIOError.systemCall(operation: .write, descriptor: STDERR_FILENO,
                                                       errno: count == 0 ? EIO : code)
                if error.isTerminalLoss { emergencyTerminalExit() }
                return
            }
        }
    }

    private func emitOsc133(_ marker: String) {
        tui?.terminal.write("\u{001B}]133;\(marker)\u{0007}")
    }

    func stopInteractiveTui(_ output: FullscreenExitOutput? = nil) {
        if tui?.mode == .altScreen, (output ?? session?.settingsManager.getFullscreenExitOutput()) == .resumeHint {
            altScreenRenderer?.stop(preserveScreen: true)
            tui?.stop()
            if let session { tui?.terminal.write("\nResume this session with: \(APP_NAME) --resume \(session.sessionId)\n") }
        } else {
            tui?.stop()
        }
    }

    private func emitSessionShutdownEvents() async {
        guard let session else { return }
        if let hookRunner = session.hookRunner {
            _ = await hookRunner.emit(SessionShutdownEvent())
        }
        await session.emitCustomToolSessionEvent(.shutdown)
    }

    /// v0.70.5: register SIGHUP/SIGTERM handlers so extensions receive `session_shutdown` and
    /// tracked detached children are killed before the process exits.
    @MainActor
    private func registerShutdownSignalHandlers() {
        unregisterShutdownSignalHandlers()
        let signals: [Int32] = [SIGTERM, SIGHUP]
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    await self?.performShutdown(fromSignal: true)
                }
            }
            source.resume()
            shutdownSignalSources.append(source)
        }
    }

    @MainActor
    private func unregisterShutdownSignalHandlers() {
        for source in shutdownSignalSources {
            source.cancel()
        }
        shutdownSignalSources.removeAll()
    }

    @MainActor
    private func handleAltEnter() async {
        guard let editor, let session else { return }
        let text = editor.getText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if session.isStreaming {
            session.followUp(text)
            pendingFollowUpMessages.append(text)
            updatePendingMessagesDisplay()
            editor.addToHistory(text)
            editor.setText("")
            scheduleRender()
        } else {
            await handleEditorSubmit(text)
        }
    }

    @MainActor
    private func handleDequeue() {
        let restored = restoreQueuedMessagesToEditor()
        if restored == 0 {
            showStatus("No queued messages to restore")
        } else {
            let suffix = restored == 1 ? "" : "s"
            showStatus("Restored \(restored) queued message\(suffix) to editor")
        }
    }

    @MainActor
    private func restoreQueuedMessagesToEditor(abort: Bool = false, currentText: String? = nil) -> Int {
        guard let session else { return 0 }
        let queued = session.clearQueue()
        let allQueued = queued.steering + queued.followUp

        pendingSteeringMessages.removeAll()
        pendingFollowUpMessages.removeAll()

        if allQueued.isEmpty {
            updatePendingMessagesDisplay()
            if abort {
                Task { await session.abort() }
            }
            return 0
        }

        let queuedText = allQueued.joined(separator: "\n\n")
        let existingText = currentText ?? editor?.getText() ?? ""
        let combined = [queuedText, existingText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        editor?.setText(combined)
        updatePendingMessagesDisplay()
        if abort {
            Task { await session.abort() }
        }
        return allQueued.count
    }

    private enum ModelCycleDirection {
        case forward
        case backward
    }

    @MainActor
    private func cycleThinkingLevel() {
        guard let session else { return }
        if let newLevel = session.cycleThinkingLevel(options: ModelMutationOptions(persist: false)) {
            footer?.invalidate()
            updateEditorBorderColor()
            showStatus("Thinking level: \(newLevel.rawValue)")
        } else {
            showStatus("Current model does not support thinking")
        }
    }

    @MainActor
    private func cycleModel(direction: ModelCycleDirection) async {
        guard let session else { return }
        recordUserModelSelection()
        do {
            let result = try await session.cycleModel(direction: direction == .forward ? .forward : .backward, options: ModelMutationOptions(persist: false))
            if let result {
                footer?.invalidate()
                updateEditorBorderColor()
                let displayName = result.model.name.isEmpty ? result.model.id : result.model.name
                let thinkingStr = result.model.reasoning && result.thinkingLevel != .off ? " (thinking: \(result.thinkingLevel.rawValue))" : ""
                showStatus("Switched to \(displayName)\(thinkingStr)")
            } else {
                let message = session.scopedModels.isEmpty ? "Only one model available" : "Only one model in scope"
                showStatus(message)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @MainActor
    private func toggleToolOutputExpansion() {
        setToolsExpanded(!toolOutputExpanded)
    }

    @MainActor
    func setToolsExpanded(_ expanded: Bool) {
        guard expanded != toolOutputExpanded else { return }
        toolOutputExpanded = expanded
        builtInHeader?.setExpanded(expanded)
        for child in loadedResourcesContainer.children {
            (child as? ExpandableText)?.setExpanded(expanded)
        }
        for child in chatContainer.children {
            if let text = child as? ExpandableText {
                text.setExpanded(expanded)
            } else if let tool = child as? ToolExecutionComponent {
                tool.setExpanded(toolOutputExpanded)
            } else if let bash = child as? BashExecutionComponent {
                bash.setExpanded(toolOutputExpanded)
            } else if let branch = child as? BranchSummaryMessageComponent {
                branch.setExpanded(toolOutputExpanded)
            } else if let compaction = child as? CompactionSummaryMessageComponent {
                compaction.setExpanded(toolOutputExpanded)
            } else if let hook = child as? HookMessageComponent {
                hook.setExpanded(toolOutputExpanded)
            } else if let customEntry = child as? CustomEntryComponent {
                customEntry.setExpanded(toolOutputExpanded)
            }
        }
        showStatus("Tool output: \(expanded ? "expanded" : "collapsed")")
    }

    @MainActor
    func toggleThinkingBlockVisibility() {
        hideThinkingBlock.toggle()
        session?.settingsManager.setHideThinkingBlock(hideThinkingBlock)

        applyThinkingBlockVisibility()
    }

    @MainActor
    func applyThinkingBlockVisibility() {
        for case let component as AssistantMessageComponent in chatContainer.children {
            component.setHideThinkingBlock(hideThinkingBlock)
        }
        streamingComponent?.setHideThinkingBlock(hideThinkingBlock)
        scheduleRender()

        showStatus("Thinking blocks: \(hideThinkingBlock ? "hidden" : "visible")")
    }

    @MainActor
    private func openExternalEditor() async {
        guard let editor, let tui else { return }
        let editorCmd = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"]
        guard let editorCmd, !editorCmd.isEmpty else {
            showWarning("No editor configured. Set VISUAL or EDITOR.")
            return
        }

        let currentText = editor.getText()
        let tmpFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("pi-editor-\(Int(Date().timeIntervalSince1970)).md")

        do {
            try currentText.write(toFile: tmpFile, atomically: true, encoding: .utf8)

            tui.stop()

            let parts = editorCmd.split(separator: " ").map(String.init)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: parts[0])
            process.arguments = Array(parts.dropFirst()) + [tmpFile]
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let newContent = (try? String(contentsOfFile: tmpFile, encoding: .utf8)) ?? currentText
                editor.setText(splitBom(newContent).text.trimmingCharacters(in: .newlines))
            }
        } catch {
            showWarning("Failed to open external editor")
        }

        try? FileManager.default.removeItem(atPath: tmpFile)

        tui.start()
        tui.requestRender()
    }

    @MainActor
    func handleClipboardImagePaste() {
        guard let editor else { return }
        do {
            if let paths = try clipboardFiles() {
                let insertion = try clipboardFileInsertion(paths, bashMode: editor.getText().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!"), text: editor.getText(), cursor: editor.getPasteCursor())
                editor.insertTextAtCursor(insertion)
                scheduleRender()
                return
            }
            switch clipboardImage() {
            case .content(let data):
                let fileName = "pi-clipboard-\(UUID().uuidString).png"
                let filePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(fileName)
                try writeClipboardImage(data, URL(fileURLWithPath: filePath))
                editor.insertTextAtCursor(filePath)
                scheduleRender()
                return
            case .error(let message): throw ClipboardPasteError.read(message)
            case .empty, .unavailable: break
            }
            switch clipboardText() {
            case .content(let text):
                if !text.isEmpty { editor.insertTextAtCursor(text); scheduleRender() }
            case .error(let message): throw ClipboardPasteError.read(message)
            case .empty, .unavailable: break
            }
        } catch {
            showError("Failed to paste from clipboard: \(error.localizedDescription)")
        }
    }

    @MainActor
    func handleEditorSubmit(_ text: String) async {
        guard let session, let editor else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("/") {
            if await handleHookCommand(trimmed) {
                editor.setText("")
                return
            }
        }

        if trimmed == "/settings" {
            await showSettingsSelector()
            editor.setText("")
            return
        }
        if trimmed == "/config" {
            editor.setText("")
            await showConfigSelector()
            return
        }
        if trimmed == "/scoped-models" {
            editor.setText("")
            await showModelsSelector()
            return
        }
        if trimmed == "/model" || trimmed.hasPrefix("/model ") {
            let searchTerm = trimmed.hasPrefix("/model ") ? String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            editor.setText("")
            await handleModelCommand(searchTerm)
            return
        }
        if trimmed == "/trust" {
            editor.setText("")
            showTrustSelector()
            return
        }
        if trimmed == "/thinking" || trimmed.hasPrefix("/thinking ") {
            let argument = trimmed == "/thinking" ? nil : String(trimmed.dropFirst(10))
            editor.setText("")
            handleThinkingCommand(argument)
            return
        }
        if trimmed == "/share" {
            editor.setText("")
            await handleShareCommand()
            return
        }
        if trimmed == "/bug" || trimmed.hasPrefix("/bug ") || trimmed.hasPrefix("/bug\n") {
            let hint = trimmed == "/bug" ? nil : String(trimmed.dropFirst(5))
            editor.setText("")
            await handleBugCommand(hint)
            return
        }
        if trimmed == "/theme" {
            showThemeSelector()
            editor.setText("")
            return
        }
        if trimmed == "/login" || trimmed.hasPrefix("/login ") {
            let providerRef = trimmed == "/login" ? nil : String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            editor.setText("")
            await handleLoginCommand(providerRef)
            return
        }
        if trimmed == "/logout" {
            editor.setText("")
            showOAuthSelector(.logout)
            return
        }
        if trimmed == "/templates" || trimmed == "/template" {
            handleTemplatesCommand()
            editor.setText("")
            return
        }
        if trimmed == "/reload" {
            editor.setText("")
            await handleReloadCommand()
            return
        }
        if trimmed.hasPrefix("/export") {
            await handleExportCommand(trimmed)
            editor.setText("")
            return
        }
        if trimmed == "/copy" {
            handleCopyCommand()
            editor.setText("")
            return
        }
        if trimmed == "/name" || trimmed.hasPrefix("/name ") {
            handleNameCommand(trimmed)
            editor.setText("")
            return
        }
        if trimmed == "/session" {
            await handleSessionCommand()
            editor.setText("")
            return
        }
        if trimmed == "/files" {
            handleFilesCommand()
            editor.setText("")
            return
        }
        if trimmed == "/changelog" {
            handleChangelogCommand()
            editor.setText("")
            return
        }
        if trimmed == "/hotkeys" {
            handleHotkeysCommand()
            editor.setText("")
            return
        }
        if trimmed == "/debug" {
            handleDebugCommand()
            editor.setText("")
            return
        }
        if trimmed == "/fork" {
            showUserMessageSelector()
            editor.setText("")
            return
        }
        if trimmed == "/clone" {
            // v0.68.0: /clone duplicates the current active branch into a new session
            // (snapshots the messages and metadata, then forks from the most recent
            // assistant entry — equivalent to fork-at-current-position rather than
            // fork-from-a-previous-user-message).
            handleCloneCommand()
            editor.setText("")
            return
        }
        if trimmed == "/tree" {
            showTreeSelector()
            editor.setText("")
            return
        }
        if trimmed == "/new" {
            handleNewSessionCommand()
            editor.setText("")
            return
        }
        if trimmed.hasPrefix("/compact") {
            let custom = trimmed.count > 8 ? String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            editor.disableSubmit = true
            handleCompactCommand(custom)
            editor.disableSubmit = false
            editor.setText("")
            return
        }
        if trimmed == "/resume" {
            showSessionSelector()
            editor.setText("")
            return
        }
        if trimmed == "/quit" || trimmed == "/exit" {
            editor.setText("")
            requestShutdown()
            return
        }

        if trimmed.hasPrefix("/skill:") {
            let spaceIndex = trimmed.firstIndex(of: " ")
            let commandName: String
            let args: String
            if let spaceIndex {
                commandName = String(trimmed[trimmed.index(after: trimmed.startIndex)..<spaceIndex])
                args = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                commandName = String(trimmed.dropFirst())
                args = ""
            }
            if let skillPath = skillCommands[commandName] {
                editor.addToHistory(trimmed)
                editor.setText("")
                await handleSkillCommand(skillPath: skillPath, args: args)
                return
            }
        }

        if trimmed.hasPrefix("!!") || trimmed.hasPrefix("!") {
            let excludeFromContext = trimmed.hasPrefix("!!")
            let commandPrefixLength = excludeFromContext ? 2 : 1
            let command = trimmed.dropFirst(commandPrefixLength).trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                return
            }
            if bashAbort != nil {
                showWarning("A bash command is already running")
                return
            }
            editor.addToHistory(trimmed)
            await handleBashCommand(command, excludeFromContext: excludeFromContext)
            isBashMode = false
            updateEditorBorderColor()
            return
        }

        if session.isStreaming {
            session.steer(trimmed)
            pendingSteeringMessages.append(trimmed)
            updatePendingMessagesDisplay()
            editor.addToHistory(trimmed)
            editor.setText("")
            scheduleRender()
            return
        }

        flushPendingBashComponents()
        editor.addToHistory(trimmed)
        await prompt(trimmed, images: nil)
    }

    func prompt(_ text: String, images: [ImageContent]?) async {
        guard let session else { return }
        if Self.usesMcpManager(text), mcpUi != nil,
           session.hookRunner?.getCommand("mcp")?.sourceInfo?.path == "builtin:mcp" {
            _ = await handleHookCommand(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        emitOsc133("B") // command start — user submitted
        emitOsc133("C") // command executed — processing started
        do {
            try await session.prompt(text, options: PromptOptions(expandSlashCommands: nil, images: images))
        } catch {
            await MainActor.run {
                self.showError(error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func usesMcpManager(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        return parts.first == "/mcp" && (parts.count == 1 || parts.dropFirst().first == "login")
    }

    @MainActor
    func handleHookCommand(_ text: String) async -> Bool {
        guard let session, let hookRunner = session.hookRunner else { return false }
        guard text.hasPrefix("/") else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let namePart = parts.first else { return false }
        let commandName = String(namePart)
        guard !commandName.isEmpty else { return false }

        let args = parts.count > 1 ? String(parts[1]) : ""
        guard let command = hookRunner.getCommand(commandName) else { return false }

        let context = hookRunner.createCommandContext()
        do {
            if Self.usesMcpManager(trimmed),
               command.sourceInfo?.path == "builtin:mcp", let mcpUi {
                await mcpUi.runManager { try await command.handler(args, context) }
            } else {
                try await command.handler(args, context)
            }
        } catch {
            hookRunner.emitError(HookError(
                hookPath: "command:\(commandName)",
                event: "command",
                error: error.localizedDescription,
                stack: Thread.callStackSymbols.joined(separator: "\n")
            ))
        }
        return true
    }

    @MainActor
    private func handleBashCommand(_ command: String, excludeFromContext: Bool = false) async {
        guard let tui, let session else { return }

        let eventResult: UserBashEventResult?
        do {
            eventResult = try await session.hookRunner?.emitUserBash(UserBashEvent(
                command: command,
                excludeFromContext: excludeFromContext,
                cwd: FileManager.default.currentDirectoryPath
            ))
        } catch {
            // user_bash fails closed (v0.86.0): the runner already reported the error;
            // never fall back to local execution.
            return
        }

        if let result = eventResult?.result {
            let component = BashExecutionComponent(command: command, ui: tui, excludeFromContext: excludeFromContext, outputPad: tuiConfiguration.outputPad)
            bashComponent = component

            let deferDisplay = session.isStreaming
            if deferDisplay {
                pendingBashComponents.append(component)
            } else {
                chatContainer.addChild(component)
            }
            updatePendingMessagesDisplay()

            if !result.output.isEmpty {
                component.appendOutput(result.output)
            }
            let truncation = result.truncated ? truncateTail(result.output) : nil
            component.setComplete(exitCode: result.exitCode, cancelled: result.cancelled, truncationResult: truncation, fullOutputPath: result.fullOutputPath)

            do {
                let message = BashExecutionMessage(
                    command: command,
                    output: result.output,
                    exitCode: result.exitCode,
                    cancelled: result.cancelled,
                    truncated: result.truncated,
                    fullOutputPath: result.fullOutputPath,
                    excludeFromContext: excludeFromContext ? true : nil
                )
                if deferDisplay {
                    pendingBashMessages.append(message)
                } else {
                    let agentMessage = makeBashExecutionAgentMessage(message)
                    session.agent.appendMessage(agentMessage)
                    _ = session.sessionManager.appendMessage(agentMessage)
                }
            }

            bashComponent = nil
            bashAbort = nil
            scheduleRender()
            return
        }

        let operations = eventResult?.operations ?? DefaultBashOperations()
        let component = BashExecutionComponent(command: command, ui: tui, excludeFromContext: excludeFromContext, outputPad: tuiConfiguration.outputPad)
        bashComponent = component

        let deferDisplay = session.isStreaming
        if deferDisplay {
            pendingBashComponents.append(component)
        } else {
            chatContainer.addChild(component)
        }
        updatePendingMessagesDisplay()
        scheduleRender()

        let abortToken = CancellationToken()
        bashAbort = abortToken
        footer?.setBashToolRunning(true)

        do {
            let result = try await executeBashWithOperations(
                command,
                operations: operations,
                options: BashExecutorOptions(onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self, let bashComponent = self.bashComponent else { return }
                        bashComponent.appendOutput(chunk)
                        self.scheduleRender()
                    }
                }, signal: abortToken)
            )

            let truncation = result.truncated ? truncateTail(result.output) : nil
            component.setComplete(exitCode: result.exitCode, cancelled: result.cancelled, truncationResult: truncation, fullOutputPath: result.fullOutputPath)

            do {
                let message = BashExecutionMessage(
                    command: command,
                    output: result.output,
                    exitCode: result.exitCode,
                    cancelled: result.cancelled,
                    truncated: result.truncated,
                    fullOutputPath: result.fullOutputPath,
                    excludeFromContext: excludeFromContext ? true : nil
                )

                if deferDisplay {
                    pendingBashMessages.append(message)
                } else {
                    let agentMessage = makeBashExecutionAgentMessage(message)
                    session.agent.appendMessage(agentMessage)
                    _ = session.sessionManager.appendMessage(agentMessage)
                }
            }
        } catch {
            component.setComplete(exitCode: nil, cancelled: false)
            showError("Bash command failed: \(error.localizedDescription)")
        }

        bashComponent = nil
        bashAbort = nil
        footer?.setBashToolRunning(false)
        scheduleRender()
    }

    @MainActor
    private func showSelector(_ builder: (_ done: @escaping () -> Void) -> (component: Component, focus: Component)) {
        guard let editorContainer, let tui else { return }

        // Holds the component so `done` can tear down its background work. Every exit path
        // (select, cancel, ctrl+C) funnels through `done`, so an in-flight catalog refresh is
        // always cancelled exactly once (#7153).
        let closable = SelectorCloseBox()

        let done: () -> Void = { [weak self] in
            guard let self else { return }
            closable.closeOnce()
            self.selectorCancel = nil
            editorContainer.clear()
            if let editor = self.editor {
                editorContainer.addChild(editor)
                tui.setFocus(editor)
            }
            self.scheduleRender()
        }

        selectorCancel = done
        let result = builder(done)
        closable.component = result.component as? SelectorClosable
        editorContainer.clear()
        editorContainer.addChild(result.component)
        tui.setFocus(result.focus)
        scheduleRender()
    }

    @MainActor
    private func showSettingsSelector() async {
        guard let session else { return }
        let settingsManager = session.settingsManager

        let availableThinking = THINKING_LEVEL_OPTIONS
        let provider = settingsManager.getDefaultProvider()
        let modelId = settingsManager.getDefaultModel()
        let defaultModel = provider.flatMap { provider in modelId.map { "\(provider)/\($0)" } } ?? "not set"

        var config = SettingsConfig(
            autoCompact: settingsManager.getCompactionEnabled(),
            showImages: settingsManager.getShowImages(),
            autoResizeImages: settingsManager.getAutoResizeImages(),
            blockImages: settingsManager.getBlockImages(),
            enableSkillCommands: settingsManager.getEnableSkillCommands(),
            steeringMode: settingsManager.getSteeringMode(),
            followUpMode: settingsManager.getFollowUpMode(),
            transport: settingsManager.getTransport(),
            cacheWarmingMode: settingsManager.getCacheWarmingMode(),
            thinkingLevel: ThinkingLevel(rawValue: settingsManager.getDefaultThinkingLevel() ?? "") ?? DEFAULT_THINKING_LEVEL,
            availableThinkingLevels: availableThinking,
            currentTheme: themeController?.getThemeSelection() ?? "system",
            availableThemes: getAvailableThemes(),
            hideThinkingBlock: hideThinkingBlock,
            showCacheMissNotices: settingsManager.getShowCacheMissNotices(),
            collapseChangelog: settingsManager.getCollapseChangelog(),
            quietStartup: settingsManager.getQuietStartup(),
            doubleEscapeAction: settingsManager.getDoubleEscapeAction(),
            editorPaddingX: settingsManager.getEditorPaddingX(),
            autocompleteMaxVisible: settingsManager.getAutocompleteMaxVisible(),
            tuiMode: tuiConfiguration.mode,
            fullscreenScrollbar: FullscreenScrollbarMode(
                rawValue: settingsManager.getFullscreenScrollbar()
            ) ?? .auto,
            mouseWheelStep: settingsManager.getMouseWheelStep(),
            mermaidEnabled: settingsManager.getMermaidEnabled(),
            mermaidRenderWhileStreaming: settingsManager.getMermaidRenderWhileStreaming(),
            latexEnabled: settingsManager.getLatexEnabled(),
            outputPad: settingsManager.getOutputPad(),
            defaultModel: defaultModel,
            currentModel: session.agent.state.model,
            availableDefaultModels: await session.modelRegistry.getAvailable(),
            modelThinkingLevels: settingsManager.getAllModelThinkingLevels(),
            fullscreenExitOutput: settingsManager.getFullscreenExitOutput(),
            fullscreenCopyOnSelect: settingsManager.getFullscreenCopyOnSelect(),
            terminalTheme: themeController?.getTerminalTheme() ?? .dark,
            thinkingCycleKey: formatKeyDisplay(keybindings.getKeys(.cycleThinkingLevel))
        )

        config.fullscreenWheelScrollLines = settingsManager.getFullscreenWheelScrollLines()

        showSelector { done in
            var callbacks = SettingsCallbacks(
                onAutoCompactChange: { [weak self] enabled in
                    settingsManager.setCompactionEnabled(enabled)
                    self?.footer?.setAutoCompactEnabled(enabled)
                },
                onShowImagesChange: { [weak self] enabled in
                    settingsManager.setShowImages(enabled)
                    self?.updateToolImages(enabled)
                },
                onAutoResizeImagesChange: { enabled in
                    settingsManager.setAutoResizeImages(enabled)
                },
                onBlockImagesChange: { enabled in
                    settingsManager.setBlockImages(enabled)
                },
                onEnableSkillCommandsChange: { [weak self] enabled in
                    settingsManager.setEnableSkillCommands(enabled)
                    self?.rebuildAutocomplete()
                },
                onSteeringModeChange: { mode in
                    settingsManager.setSteeringMode(mode)
                    session.agent.steeringMode = AgentSteeringMode(rawValue: mode) ?? .oneAtATime
                },
                onFollowUpModeChange: { mode in
                    settingsManager.setFollowUpMode(mode)
                    session.agent.followUpMode = AgentFollowUpMode(rawValue: mode) ?? .oneAtATime
                },
                onTransportChange: { transport in
                    settingsManager.setTransport(transport)
                    session.agent.transport = transport
                },
                onCacheWarmingModeChange: { mode in
                    Task { @MainActor in await session.setCacheWarmingMode(mode) }
                },
                onThinkingLevelChange: { _ in },
                onThemeChange: { [weak self] name in
                    settingsManager.setTheme(name)
                    self?.themeController?.setThemeSetting(name)
                },
                onThemePreview: { [weak self] name in self?.themeController?.preview(name) },
                onHideThinkingBlockChange: { [weak self] hide in
                    self?.hideThinkingBlock = hide
                    settingsManager.setHideThinkingBlock(hide)
                    self?.applyThinkingBlockVisibility()
                },
                onShowCacheMissNoticesChange: { [weak self] show in
                    settingsManager.setShowCacheMissNotices(show)
                    self?.renderInitialMessages()
                },
                onCollapseChangelogChange: { collapse in
                    settingsManager.setCollapseChangelog(collapse)
                },
                onQuietStartupChange: { quiet in
                    settingsManager.setQuietStartup(quiet)
                },
                onDoubleEscapeActionChange: { action in
                    settingsManager.setDoubleEscapeAction(action)
                },
                onEditorPaddingXChange: { [weak self] padding in
                    settingsManager.setEditorPaddingX(padding)
                    self?.defaultEditor?.setPaddingX(padding)
                    self?.editor?.setPaddingX(padding)
                    self?.scheduleRender()
                },
                onAutocompleteMaxVisibleChange: { [weak self] maxVisible in
                    settingsManager.setAutocompleteMaxVisible(maxVisible)
                    self?.defaultEditor?.setAutocompleteMaxVisible(maxVisible)
                    self?.editor?.setAutocompleteMaxVisible(maxVisible)
                    self?.scheduleRender()
                },
                onTuiModeChange: { [weak self] mode in
                    guard let self else { return }
                    if self.switchTuiMode(mode) {
                        settingsManager.setTuiMode(mode.rawValue)
                    } else {
                        self.showStatus("Close active overlays before changing TUI mode")
                    }
                },
                onFullscreenScrollbarChange: { [weak self] mode in
                    settingsManager.setFullscreenScrollbar(mode.rawValue)
                    self?.setFullscreenScrollbar(mode)
                },
                onMouseWheelStepChange: { [weak self] step in
                    settingsManager.setMouseWheelStep(step)
                    self?.setFullscreenWheelScrollLines(.lines(step))
                },
                onMermaidEnabledChange: { [weak self] enabled in
                    settingsManager.setMermaidEnabled(enabled)
                    self?.tuiConfiguration.mermaidEnabled = enabled
                    self?.refreshMarkdownRendering()
                },
                onMermaidRenderWhileStreamingChange: { [weak self] enabled in
                    settingsManager.setMermaidRenderWhileStreaming(enabled)
                    self?.tuiConfiguration.mermaidRenderWhileStreaming = enabled
                    self?.refreshMarkdownRendering()
                },
                onLatexEnabledChange: { [weak self] enabled in
                    settingsManager.setLatexEnabled(enabled)
                    self?.tuiConfiguration.latexEnabled = enabled
                    self?.refreshMarkdownRendering()
                },
                onOutputPadChange: { [weak self] padding in
                    settingsManager.setOutputPad(padding)
                    self?.tuiConfiguration.outputPad = padding == 0 ? 0 : 1
                    if let self {
                        for container in [self.chatContainer, self.pendingMessagesContainer].compactMap({ $0 }) {
                            for child in container.children {
                                (child as? OutputPaddingSetting)?.setOutputPad(self.tuiConfiguration.outputPad)
                            }
                        }
                        self.refreshMarkdownRendering()
                    }
                },
                onCancel: { done() },
                onModelThinkingLevelChange: { [weak self] provider, modelId, level in
                    settingsManager.setModelThinkingLevel(provider, modelId, level)
                    let current = session.agent.state.model
                    if current.provider == provider && current.id == modelId {
                        session.setThinkingLevel(level, options: ModelMutationOptions(persist: false))
                        self?.footer?.invalidate()
                        self?.updateEditorBorderColor()
                    }
                },
                onModelThinkingLevelRemove: { [weak self] provider, modelId in
                    settingsManager.removeModelThinkingLevel(provider, modelId)
                    let current = session.agent.state.model
                    if current.provider == provider && current.id == modelId {
                        session.setThinkingLevel(ThinkingLevel(rawValue: settingsManager.getDefaultThinkingLevel() ?? "") ?? DEFAULT_THINKING_LEVEL, options: ModelMutationOptions(persist: false))
                        self?.footer?.invalidate()
                        self?.updateEditorBorderColor()
                    }
                },
                onFullscreenExitOutputChange: { settingsManager.setFullscreenExitOutput($0) },
                onFullscreenCopyOnSelectChange: { [weak self] enabled in
                    settingsManager.setFullscreenCopyOnSelect(enabled)
                    self?.altScreenRenderer?.setCopyOnSelect(enabled)
                }
            )

            callbacks.onFullscreenWheelScrollLinesChange = { [weak self] lines in
                settingsManager.setFullscreenWheelScrollLines(lines)
                self?.setFullscreenWheelScrollLines(lines)
            }
            let selector = SettingsSelectorComponent(config: config, callbacks: callbacks)
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showConfigSelector() async {
        guard let session, let tui, let editorContainer, let currentEditor = editor else { return }
        if session.isStreaming {
            showWarning("Wait for the current response to finish before opening config.")
            return
        }
        if session.isCompacting {
            showWarning("Wait for compaction to finish before opening config.")
            return
        }

        let loader = BorderedLoader(tui: tui, theme: theme, message: "Loading resources...")
        editorContainer.clear()
        editorContainer.addChild(loader)
        tui.setFocus(loader)
        ui.requestRender()

        let cwd = FileManager.default.currentDirectoryPath
        let agentDir = getAgentDir()
        let packageManager = DefaultPackageManager(cwd: cwd, agentDir: agentDir,
            settingsManager: session.settingsManager, builtinExtensions: builtInExtensions.map(\.name))

        let resolvedPaths: ResolvedPaths
        let globalResolvedPaths: ResolvedPaths
        do {
            resolvedPaths = try await packageManager.resolve(onMissing: nil)
            globalResolvedPaths = try await resolveBuiltinExtensionPaths(settingsManager: session.settingsManager,
                names: builtInExtensions.map(\.name), cwd: cwd, agentDir: agentDir, projectTrusted: false)
        } catch {
            loader.dispose()
            editorContainer.clear()
            editorContainer.addChild(currentEditor)
            tui.setFocus(currentEditor)
            ui.requestRender()
            showError("Failed to load resources: \(error.localizedDescription)")
            return
        }

        loader.dispose()
        showSelector { done in
            let selector = ConfigSelectorComponent(
                resolvedPaths: resolvedPaths,
                settingsManager: session.settingsManager,
                cwd: cwd,
                agentDir: agentDir,
                onClose: {
                    done()
                },
                onExit: {
                    done()
                },
                requestRender: { [weak self] in
                    self?.ui.requestRender()
                },
                globalResolvedPaths: globalResolvedPaths
            )
            return (component: selector, focus: selector.getResourceList())
        }
    }

    @MainActor
    func handleThinkingCommand(_ searchTerm: String?) {
        guard let session else { return }
        let levels = session.getAvailableThinkingLevels()
        let searchTerm = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let searchTerm, !searchTerm.isEmpty else {
            showSelector { done in
                let selector = ThinkingSelectorComponent(
                    currentLevel: session.agent.state.thinkingLevel, availableLevels: levels,
                    onSelect: { [weak self] in self?.selectThinkingLevel($0, persist: false); done() },
                    onCancel: { done() },
                    onSelectAsDefault: { [weak self] in self?.selectThinkingLevel($0, persist: true); done() },
                    defaultThinkingLevel: ThinkingLevel(rawValue: session.settingsManager.getDefaultThinkingLevel() ?? "") ?? DEFAULT_THINKING_LEVEL,
                    cycleKey: self.formatKeyDisplay(self.keybindings.getKeys(.cycleThinkingLevel)))
                return (component: selector, focus: selector)
            }
            return
        }
        guard let level = levels.first(where: { $0.rawValue == searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) else {
            showError("Unknown thinking level \"\(searchTerm)\". Available levels: \(levels.map(\.rawValue).joined(separator: ", ")).")
            return
        }
        selectThinkingLevel(level, persist: false)
    }

    func selectThinkingLevel(_ level: ThinkingLevel, persist: Bool) {
        session?.setThinkingLevel(level, options: ModelMutationOptions(persist: persist))
        footer?.invalidate()
        updateEditorBorderColor()
        showStatus(persist ? "Default thinking level: \(level.rawValue)" : "Thinking level: \(level.rawValue)")
    }

    @MainActor
    private func handleModelCommand(_ searchTerm: String?) async {
        guard let session else { return }
        let trimmed = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            showModelSelector()
            return
        }
        recordUserModelSelection()

        if let model = await findExactModelMatch(trimmed) {
            do {
                try await session.setModel(model, options: ModelMutationOptions(persist: false))
                footer?.invalidate()
                updateEditorBorderColor()
                showStatus("Model: \(model.id)")
            } catch {
                showError(error.localizedDescription)
            }
            return
        }

        showModelSelector(initialSearchInput: trimmed)
    }

    /// `/model <name>`. Checks the cached catalogs first and only pays for a network refresh when
    /// the name is not already known (#7443) — a hit never waits on the network. A scoped session
    /// never refreshes at all, because its model set is fixed.
    @MainActor
    private func findExactModelMatch(_ searchTerm: String) async -> Model? {
        guard let session else { return nil }
        guard let reference = ModelReference(searchTerm) else { return nil }

        let scoped = session.scopedModels
        if !scoped.isEmpty {
            return reference.exactMatch(in: scoped.map { $0.model })
        }

        let cached = await session.modelRegistry.getAvailable()
        if let cachedMatch = reference.exactMatch(in: cached) {
            return cachedMatch
        }

        showStatus("Refreshing model catalogs…")
        let outcome = await runBoundedCatalogRefresh(
            registry: session.modelRegistry,
            signal: CancellationToken()
        )
        if let warning = CatalogRefreshStatus.exactMatchWarning(outcome) {
            showWarning(warning)
        }

        return reference.exactMatch(in: await session.modelRegistry.getAvailable())
    }

    @MainActor
    private func showModelSelector(initialSearchInput: String? = nil) {
        guard let session, let tui else { return }
        showSelector { done in
            let select: (Model, Bool) -> Void = { [weak self] model, persist in
                self?.recordUserModelSelection()
                Task { @MainActor in
                    do {
                        try await session.setModel(model, options: ModelMutationOptions(persist: persist))
                        self?.footer?.invalidate()
                        self?.updateEditorBorderColor()
                        done()
                        self?.showStatus(persist ? "Default model: \(model.provider)/\(model.id)" : "Model: \(model.id)")
                    } catch { done(); self?.showError(error.localizedDescription) }
                }
            }
            let settings = session.settingsManager
            let defaultModel = settings.getDefaultProvider().flatMap { provider in
                settings.getDefaultModel().map { ModelSelection(provider: provider, id: $0) }
            }
            let selector = ModelSelectorComponent(
                tui: tui, currentModel: session.agent.state.model, defaultModel: defaultModel,
                modelRegistry: session.modelRegistry, scopedModels: session.scopedModels,
                onSelect: { select($0, false) }, onCancel: { done() },
                initialSearchInput: initialSearchInput, onSelectAsDefault: { select($0, true) }
            )
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showModelsSelector() async {
        guard let session else { return }
        // Render whatever is cached immediately; the catalogs refresh in the background below
        // and the selector is updated in place (#7153).
        var allModels = await session.modelRegistry.getAvailable()

        let sessionScopedModels = session.scopedModels
        let hasSessionScope = !sessionScopedModels.isEmpty

        var enabledModelIds: [String] = []
        var hasFilter = false

        /// Re-resolves the configured `enabledModels` patterns against the registry. Used for the
        /// initial render and again after a background refresh brings in new models.
        let configuredEnabledIds: () async -> [String] = {
            guard let patterns = session.settingsManager.getEnabledModels(), !patterns.isEmpty else {
                return []
            }
            let scoped = await resolveModelScope(patterns, session.modelRegistry)
            var ids = scoped.map { "\($0.model.provider)/\($0.model.id)" }
            for pattern in patterns {
                if await resolveModelScope([pattern], session.modelRegistry).isEmpty, !ids.contains(pattern) { ids.append(pattern) }
            }
            return ids
        }

        if hasSessionScope {
            enabledModelIds = sessionScopedModels.map { "\($0.model.provider)/\($0.model.id)" }
            hasFilter = true
        } else if let patterns = session.settingsManager.getEnabledModels(), !patterns.isEmpty {
            hasFilter = true
            enabledModelIds = await configuredEnabledIds()
        }

        var currentEnabledIds = enabledModelIds

        let updateSessionModels: ([String]) async -> Void = { enabledIds in
            let availableIds = Set(allModels.map { "\($0.provider)/\($0.id)" })
            let enabledAvailable = enabledIds.filter { availableIds.contains($0) }
            if !enabledAvailable.isEmpty && !availableIds.isSubset(of: Set(enabledIds)) {
                let currentThinkingLevel = session.agent.state.thinkingLevel
                let scoped = await resolveModelScope(enabledAvailable, session.modelRegistry)
                let resolved = scoped.map { scopedModel in
                    let level = scopedModel.isThinkingExplicit ? (scopedModel.thinkingLevel ?? .off) : currentThinkingLevel
                    return ScopedModel(model: scopedModel.model, thinkingLevel: level, isThinkingExplicit: scopedModel.isThinkingExplicit)
                }
                session.setScopedModels(resolved)
                self.scopedModels = resolved
            } else {
                session.setScopedModels([])
                self.scopedModels = []
            }
        }

        // Set once the user edits the scope, so the background refresh never overwrites their work.
        var selectionChanged = false

        showSelector { done in
            let selector = ScopedModelsSelectorComponent(
                config: ModelsConfig(
                    allModels: allModels,
                    enabledModelIds: currentEnabledIds,
                    hasEnabledModelsFilter: hasFilter,
                    refreshStatus: "Refreshing model catalogs…"
                ),
                callbacks: ModelsCallbacks(
                    onChange: { enabledIds in
                        selectionChanged = true
                        let ids = enabledIds ?? []
                        currentEnabledIds = ids
                        Task { await updateSessionModels(ids) }
                    },
                    onPersist: { enabledIds in
                        let allIds = Set(allModels.map { "\($0.provider)/\($0.id)" })
                        let normalized = enabledIds.flatMap { $0.count == allModels.count && $0.allSatisfy { allIds.contains($0) } ? nil : $0 }
                        session.settingsManager.setEnabledModels(normalized)
                        self.showStatus("Model selection saved to settings")
                    },
                    onCancel: {
                        done()
                        self.ui.requestRender()
                    }
                )
            )

            // Background refresh over the cached list. `showSelector` cancels `refreshSignal`
            // through `closeSelector()` on every exit path, so closing stops the fetch (#7153).
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await runBoundedCatalogRefresh(
                    registry: session.modelRegistry,
                    signal: selector.refreshSignal
                )
                guard !selector.isClosed else { return }

                allModels = await session.modelRegistry.getAvailable()
                if !selectionChanged && !hasSessionScope {
                    currentEnabledIds = await configuredEnabledIds()
                    selector.updateModels(allModels, enabledModelIds: .some(hasFilter ? currentEnabledIds : nil))
                } else {
                    selector.updateModels(allModels)
                }
                if hasFilter {
                    await updateSessionModels(currentEnabledIds)
                }

                let status = CatalogRefreshStatus.scopedModelsMessage(outcome)
                selector.setRefreshStatus(status.text, isError: status.isError)
                self.ui.requestRender()
            }

            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showTrustSelector() {
        guard let session else { return }
        let settings = session.settingsManager
        let cwd = session.sessionManager.getCwd()
        let saved = settings.getGlobalSettings().projectTrust ?? [:]
        let ancestor = saved.keys.filter { cwd == $0 || cwd.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        let decision = ancestor.map { ProjectTrustUpdate(path: $0, decision: saved[$0]) }
        showSelector { done in
            let selector = ProjectTrustSelectorComponent(cwd: cwd, options: getProjectTrustOptions(cwd), onSelect: { [weak self] selection in
                settings.applyProjectTrustUpdates(selection.updates)
                done()
                self?.showStatus("Saved trust decision: \(selection.trusted ? "trusted" : "untrusted"). Restart \(APP_NAME) for this to take effect.")
            }, onCancel: { done() }, savedDecision: decision,
               projectTrusted: settings.getProjectTrust(cwd) ?? !hasTrustRequiringProjectResources(cwd))
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showThemeSelector() {
        guard let settingsManager = session?.settingsManager else { return }
        let current = themeController?.getThemeSelection() ?? "system"
        showSelector { done in
            let selector = ThemeSelectorComponent(
                currentTheme: current,
                onSelect: { [weak self] name in
                    settingsManager.setTheme(name)
                    self?.themeController?.setThemeSetting(name)
                    done()
                    self?.showStatus("Theme: \(name)")
                },
                onCancel: {
                    self.themeController?.preview(current)
                    done()
                },
                onPreview: { name in
                    self.themeController?.preview(name)
                }
            )
            return (component: selector, focus: selector.getSelectList())
        }
    }

    @MainActor
    private func showUserMessageSelector() {
        guard let session else { return }
        let messages = session.getUserMessagesForForking()
        guard !messages.isEmpty else {
            showStatus("No messages to fork from")
            return
        }

        var isForking = false
        showSelector { done in
            let selector = UserMessageSelectorComponent(messages: messages.map { (id: $0.entryId, text: $0.text, timestamp: nil) }, onSelect: { [weak self] entryId in
                guard !isForking else { return }
                isForking = true
                done()
                Task {
                    guard let self else { return }
                    do {
                        let result = try await session.fork(entryId)
                        if result.cancelled {
                            self.scheduleRender()
                            return
                        }
                        self.reportingManualCompaction = false
                        self.programStatus.reset()
                        self.chatContainer.clear()
                        self.renderInitialMessages()
                        self.editor?.setText(result.selectedText)
                        self.showStatus("Forked to new session")
                    } catch {
                        self.showError(error.localizedDescription)
                    }
                }
            }, onCancel: {
                done()
            })
            return (component: selector, focus: selector.getMessageList())
        }
    }

    @MainActor
    private func showTreeSelector() {
        guard let session else { return }
        if session.isCompacting { return }
        let tree = session.sessionManager.getTree()
        let leafId = session.sessionManager.getLeafId()
        let height = tui?.terminal.rows ?? 24

        showSelector { done in
            let selector = TreeSelectorComponent(
                tree: tree,
                currentLeafId: leafId,
                terminalHeight: height,
                onSelect: { [weak self] entryId in
                    done()
                    Task {
                        guard let self else { return }
                        guard !session.isCompacting else { return }
                        let result = await session.navigateTree(entryId, summarize: false, customInstructions: nil)
                        guard !session.isCompacting else { return }
                        if result.cancelled {
                            self.showStatus("Navigation cancelled")
                            return
                        }
                        self.chatContainer.clear()
                        self.renderInitialMessages()
                        if let editorText = result.editorText {
                            self.editor?.setText(editorText)
                        }
                        self.showStatus("Navigated to selected point")
                    }
                },
                onCancel: {
                    done()
                },
                onLabelChange: { entryId, label in
                    _ = try? session.sessionManager.appendLabelChange(entryId, label)
                }
            )
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    private func showSessionSelector() {
        guard let session else { return }
        showSelector { done in
            let selector = SessionSelectorComponent(
                currentSessionsLoader: { onPartial in
                    try await SessionManager.list(session.sessionManager.getCwd(), session.sessionManager.getSessionDir(), onPartial: onPartial)
                },
                allSessionsLoader: { onPartial in
                    try await SessionManager.listAll(onPartial: onPartial)
                },
                onSelect: { [weak self] sessionPath in
                    guard let self else { return }
                    done()
                    Task { @MainActor in
                        await self.handleResumeSession(sessionPath)
                    }
                },
                onCancel: { [weak self] in
                    done()
                    self?.ui.requestRender()
                },
                onExit: { [weak self] in
                    self?.requestShutdown()
                },
                requestRender: { [weak self] in
                    self?.ui.requestRender()
                }
            )
            return (component: selector, focus: selector.getSessionList())
        }
    }

    @MainActor
    func handleResumeSession(_ sessionPath: String) async {
        guard let session else { return }

        if let loadingAnimation {
            loadingAnimation.stop()
            self.loadingAnimation = nil
        }
        clearWorkingIndicator()

        pendingMessagesContainer?.clear()
        pendingSteeringMessages.removeAll()
        pendingFollowUpMessages.removeAll()
        pendingBashComponents.removeAll()
        pendingBashMessages.removeAll()
        streamingComponent = nil
        streamingMessage = nil
        pendingTools.removeAll()

        let switched = await session.switchSession(sessionPath)
        guard switched else {
            showStatus("Resume cancelled")
            return
        }

        reportingManualCompaction = false
        programStatus.reset()
        chatContainer.clear()
        renderInitialMessages()
        showStatus("Resumed session")
    }

    @MainActor
    private func showLoginSelector(_ builder: (_ done: @escaping () -> Void) -> (component: Component, focus: Component)) {
        var component: Component?
        showSelector { done in
            let result = builder(done)
            component = result.component
            return result
        }
        // Ctrl+C must take the same back path as Escape.
        selectorCancel = { component?.handleInput("\u{001B}") }
    }

    @MainActor
    func showOAuthSelector(_ mode: OAuthSelectorMode) {
        if mode == .login {
            showLoginAuthTypeSelector()
            return
        }
        guard let session else { return }
        let registry = session.modelRegistry
        let options = registry.authStorage.listCredentials().map { credential in
            let type: AuthType = credential.type == .oauth ? .oauth : .apiKey
            return AuthSelectorProvider(id: credential.providerId,
                name: registry.getProviderDisplayName(credential.providerId), authType: type,
                status: AuthSelectorStatus(type: type, source: "stored credential"),
                subscription: registry.getLoginProvider(credential.providerId)?.oauth?.isSubscription == true)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !options.isEmpty else {
            showStatus("No stored credentials to remove. /logout only removes credentials saved by /login; environment variables and models.json config are unchanged.")
            return
        }
        showLoginSelector { done in
            let selector = OAuthSelectorComponent(mode: .logout, providers: options, onSelect: { [weak self] id, type in
                done()
                guard let option = options.first(where: { $0.id == id && $0.authType == type }) else { return }
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        await registry.logout(id)
                        try await self.synchronizeProviderAuthentication(id, operation: .logout)
                        await session.refreshActiveModel()
                        self.showStatus(type == .oauth
                            ? "Logged out of \(option.name)"
                            : "Removed stored API key for \(option.name). Environment variables and models.json config are unchanged.")
                        self.refreshProviderCatalogInBackground(providerId: id, actionLabel: "Logged out of \(option.name)")
                    } catch {
                        let message = error.localizedDescription
                        self.showError(error is CredentialSynchronizationError
                            ? "Credentials removed for \(option.name), but local model state could not be synchronized: \(message)"
                            : "Logout failed: \(message)")
                    }
                }
            }, onCancel: { done() })
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    func handleLoginCommand(_ providerRef: String?) async {
        guard let session else { return }
        let ref = providerRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ref.isEmpty else { showLoginAuthTypeSelector(); return }
        let options = getLoginProviderOptions(session.modelRegistry)
        let matches = options.filter { $0.id.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if matches.count == 1 {
            await startProviderLogin(matches[0])
        } else if matches.count > 1 && Set(matches.map(\.id)).count == 1 {
            showLoginAuthTypeSelector(matches)
        } else {
            showLoginProviderSelector(initialSearchInput: ref)
        }
    }

    @MainActor
    func showLoginAuthTypeSelector(_ providerOptions: [AuthSelectorProvider]? = nil) {
        let oauthOption = providerOptions?.first { $0.authType == .oauth }
        let accountLabel: String
        if case .oauth(let method) = oauthOption?.method {
            accountLabel = method.loginLabel ?? "Sign in with an account"
        } else { accountLabel = "Sign in with an account" }
        let apiKeyLabel = "Sign in with an API key"
        let types = providerOptions.map { Set($0.map(\.authType)) } ?? Set([.oauth, .apiKey])
        var labels: [String] = []
        if types.contains(.oauth) { labels.append(accountLabel) }
        if types.contains(.apiKey) { labels.append(apiKeyLabel) }
        // Radius can add a final option with shimmer and an onBack to this menu.
        guard !labels.isEmpty else { showStatus("No login methods available."); return }
        if let providerOptions, labels.count == 1, let option = providerOptions.first {
            Task { @MainActor in await self.startProviderLogin(option) }
            return
        }
        let title = providerOptions?.first.map { "Select authentication method for \($0.name):" } ?? "Select authentication method:"
        showLoginSelector { done in
            let selector = HookSelectorComponent(title: title, options: labels, onSelect: { [weak self] label in
                done()
                guard let self else { return }
                let type: AuthType = label == accountLabel ? .oauth : .apiKey
                if let providerOptions, let option = providerOptions.first(where: { $0.authType == type }) {
                    Task { @MainActor in await self.startProviderLogin(option, onBack: { self.showLoginAuthTypeSelector(providerOptions) }) }
                } else {
                    self.showLoginProviderSelector(type)
                }
            }, onCancel: { done() })
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    func showLoginProviderSelector(_ authType: AuthType? = nil, initialSearchInput: String? = nil) {
        guard let session else { return }
        let options = getLoginProviderOptions(session.modelRegistry, authType: authType)
        guard !options.isEmpty else {
            showStatus(authType == .oauth ? "No account providers available." : authType == .apiKey ? "No API key providers available." : "No login providers available.")
            return
        }
        showLoginSelector { done in
            let selector = OAuthSelectorComponent(mode: .login, providers: options, onSelect: { [weak self] id, type in
                done()
                guard let self, let option = options.first(where: { $0.id == id && $0.authType == type }) else { return }
                Task { @MainActor in
                    await self.startProviderLogin(option, onBack: { self.showLoginProviderSelector(authType, initialSearchInput: initialSearchInput) })
                }
            }, onCancel: { [weak self] in
                done()
                if authType != nil { self?.showLoginAuthTypeSelector() }
            }, initialSearchInput: initialSearchInput)
            return (component: selector, focus: selector)
        }
    }

    @MainActor
    func startProviderLogin(_ option: AuthSelectorProvider, onBack: (() -> Void)? = nil) async {
        guard let session else { return }
        if option.authType == .oauth, let provider = OAuthProvider(rawValue: option.id) {
            await handleOAuthLogin(provider, providerName: option.name, authStorage: session.modelRegistry.authStorage, onBack: onBack)
        } else if case .apiKey(let method) = option.method, method.login != nil {
            await showApiKeyLoginDialog(option, onBack: onBack)
        } else {
            showAmbientAuthDialog(option, onBack: onBack)
        }
    }

    @MainActor
    private func mountLoginDialog(_ dialog: LoginDialogComponent) -> (() -> Void)? {
        guard let tui, let editorContainer, let editor else { return nil }
        let savedText = editor.getText()
        editorContainer.clear()
        editorContainer.addChild(dialog)
        tui.setFocus(dialog)
        selectorCancel = { dialog.handleInput("\u{001B}") }
        tui.requestRender()
        return { [weak self] in
            self?.selectorCancel = nil
            editorContainer.clear()
            editorContainer.addChild(editor)
            editor.setText(savedText)
            tui.setFocus(editor)
            tui.requestRender()
        }
    }

    @MainActor
    func showAmbientAuthDialog(_ option: AuthSelectorProvider, onBack: (() -> Void)? = nil) {
        guard let tui else { return }
        var restoreEditor: (() -> Void)?
        let dialog = LoginDialogComponent(tui: tui, providerId: option.id, providerName: option.name, title: "\(option.name) setup") { _, _ in
            restoreEditor?()
            onBack?()
        }
        let methodName: String
        if case .apiKey(let method) = option.method { methodName = method.name } else { methodName = "Authentication" }
        dialog.showInfo("\(methodName) is configured outside pi.", links: [], showCloseHint: true)
        restoreEditor = mountLoginDialog(dialog)
    }

    @MainActor
    func showAuthSelect(dialog: LoginDialogComponent, prompt: OAuthSelectPrompt) async throws -> String {
        guard !dialog.signal.isCancelled, let editorContainer, let tui else { throw LoginDialogError.cancelled }
        // Radius can supply its intro text as this selector's description.
        @MainActor final class SelectionState {
            var continuation: CheckedContinuation<String, Error>?
            var removeCancellation: (@Sendable () -> Void)?
        }
        let state = SelectionState()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            let finish: @MainActor @Sendable (Result<String, Error>) -> Void = { [weak self] result in
                guard let continuation = state.continuation else { return }
                state.continuation = nil
                state.removeCancellation?()
                editorContainer.clear()
                editorContainer.addChild(dialog)
                tui.setFocus(dialog)
                self?.selectorCancel = { dialog.handleInput("\u{001B}") }
                tui.requestRender()
                continuation.resume(with: result)
            }
            let selector = HookSelectorComponent(title: prompt.message, options: prompt.options.map(\.label), onSelect: { label in
                if dialog.signal.isCancelled { finish(.failure(LoginDialogError.cancelled)); return }
                if let id = prompt.options.first(where: { $0.label == label })?.id { finish(.success(id)) }
                else { finish(.failure(LoginDialogError.cancelled)) }
            }, onCancel: { finish(.failure(LoginDialogError.cancelled)) })
            editorContainer.clear()
            editorContainer.addChild(selector)
            tui.setFocus(selector)
            selectorCancel = { finish(.failure(LoginDialogError.cancelled)) }
            tui.requestRender()
            state.removeCancellation = dialog.signal.onCancel {
                Task { @MainActor in finish(.failure(LoginDialogError.cancelled)) }
            }
        }
    }

    @MainActor
    func showApiKeyLoginDialog(_ option: AuthSelectorProvider, onBack: (() -> Void)?) async {
        guard let session, let tui else { return }
        let needsDefaultSelection = !session.modelRegistry.hasConfiguredAuth(session.agent.state.model)
        let dialog = LoginDialogComponent(tui: tui, providerId: option.id, providerName: option.name) { _, _ in }
        if option.id == "amazon-bedrock" {
            dialog.showDetails([
                theme.fg(.text, "You can also use an AWS profile, IAM keys, or role-based credentials."),
                theme.fg(.muted, "See:"),
                theme.fg(.accent, "  \(getDocsPath())/providers.md")
            ])
        }
        guard let restoreEditor = mountLoginDialog(dialog) else { return }
        let interaction = ProviderAuthInteraction(prompt: { [weak self] prompt in
            guard !dialog.signal.isCancelled else { throw LoginDialogError.cancelled }
            switch prompt {
            case .text(let message, let placeholder): return try await dialog.showPrompt(message, placeholder)
            case .secret(let message, let placeholder): return try await dialog.showPrompt(message, placeholder, secret: true)
            case .select(let prompt):
                guard let self else { throw LoginDialogError.cancelled }
                return try await self.showAuthSelect(dialog: dialog, prompt: prompt)
            }
        }, notify: { event in
            guard !dialog.signal.isCancelled else { return }
            switch event {
            case .info(let message, let links): dialog.showInfo(message, links: links)
            case .progress(let message): dialog.showProgress(message)
            }
        }, signal: dialog.signal)
        do {
            programStatus.setBlocked(source: "login", status: BlockedStatus(kind: .auth, message: "Log in to \(option.name)"))
            do {
                defer { programStatus.setBlocked(source: "login", status: nil) }
                try await session.modelRegistry.loginApiKey(option.id, interaction: interaction)
            }
            try await synchronizeProviderAuthentication(option.id, operation: .login)
            await session.refreshActiveModel()
            restoreEditor()
            completeProviderAuthentication(providerId: option.id, actionLabel: "Saved API key for \(option.name)", selectDefaultAfterLogin: needsDefaultSelection)
        } catch {
            restoreEditor()
            let message = error.localizedDescription
            if error is CredentialSynchronizationError {
                showError("Saved API key for \(option.name), but local model state could not be synchronized: \(message)")
            } else if message == "Login cancelled" { onBack?() }
            else { showError("Failed to save API key for \(option.name): \(message)") }
        }
    }

    @MainActor
    private func synchronizeProviderAuthentication(_ providerId: String, operation: CredentialSynchronizationOperation) async throws {
        guard let registry = session?.modelRegistry else { return }
        // Registry login/logout do not return their local refresh result. Read it here
        // so a committed credential can report a provider synchronization failure.
        let result = await registry.refresh(ModelsRefreshOptions(allowNetwork: false))
        if let cause = result.errors[providerId] {
            throw CredentialSynchronizationError(providerId: providerId, operation: operation,
                credential: registry.authStorage.get(providerId), cause: cause)
        }
    }

    @MainActor
    private func completeProviderAuthentication(providerId: String, actionLabel: String, selectDefaultAfterLogin: Bool) {
        showStatus("\(actionLabel). Credentials saved to \(getAuthPath())")
        // Radius can offer its MCP server here and use the first catalog model as a fallback.
        refreshProviderCatalogInBackground(providerId: providerId, actionLabel: actionLabel, selectAfterLogin: selectDefaultAfterLogin)
    }

    @MainActor
    private func handleOAuthLogin(_ provider: OAuthProvider, providerName: String, authStorage: AuthStorage, onBack: (() -> Void)?) async {
        guard let session, let tui else { return }
        let needsDefaultSelection = !session.modelRegistry.hasConfiguredAuth(session.agent.state.model)
        let dialog = LoginDialogComponent(tui: tui, providerId: provider.rawValue, providerName: providerName) { _, _ in }
        guard let restoreEditor = mountLoginDialog(dialog) else { return }
        final class ManualInputState {
            var task: Task<String, Error>?
        }
        let manualInputState = ManualInputState()

        let needsManualInput = provider == .openAICodex || provider == .googleGeminiCli || provider == .googleAntigravity

        let manualInputProvider: (@MainActor @Sendable () async throws -> String?)?
        if needsManualInput {
            manualInputProvider = { () async throws -> String? in
                if let task = manualInputState.task {
                    return try await task.value
                }
                let value = try await dialog.showManualInput("Paste redirect URL below, or complete login in browser:")
                return value
            }
        } else {
            manualInputProvider = nil
        }

        let callbacks = OAuthLoginCallbacks(
            onAuth: { info in
                guard !dialog.signal.isCancelled else { return }
                dialog.showAuth(info.url, info.instructions)
                if needsManualInput {
                    manualInputState.task = Task { @MainActor in
                        return try await dialog.showManualInput("Paste redirect URL below, or complete login in browser:")
                    }
                } else if provider == .githubCopilot {
                    dialog.showWaiting("Waiting for browser authentication...")
                }
            },
            onPrompt: { prompt in
                try await dialog.showPrompt(prompt.message, prompt.placeholder)
            },
            onProgress: { message in
                guard !dialog.signal.isCancelled else { return }
                dialog.showProgress(message)
            },
            onManualCodeInput: manualInputProvider,
            signal: dialog.signal,
            getDeviceId: interactiveOAuthDeviceIdProvider(session.settingsManager),
            onSelect: { [weak self] prompt in
                guard let self else { throw LoginDialogError.cancelled }
                return try await self.showAuthSelect(dialog: dialog, prompt: prompt)
            }
        )

        do {
            programStatus.setBlocked(source: "login", status: BlockedStatus(kind: .auth, message: "Log in to \(providerName)"))
            do {
                defer { programStatus.setBlocked(source: "login", status: nil) }
                try await authStorage.login(provider, callbacks: callbacks)
            }
            // Local credential consistency first — this must be synchronous so the session picks
            // up the new credential immediately.
            try await synchronizeProviderAuthentication(provider.rawValue, operation: .login)
            await session.refreshActiveModel()
            restoreEditor()
            manualInputState.task?.cancel()
            completeProviderAuthentication(providerId: provider.rawValue, actionLabel: "Logged in to \(providerName)", selectDefaultAfterLogin: needsDefaultSelection)
            // Radius can offer its MCP server after OAuth success.
        } catch {
            manualInputState.task?.cancel()
            restoreEditor()
            let message = error.localizedDescription
            if error is CredentialSynchronizationError {
                showError("Logged in to \(providerName), but local model state could not be synchronized: \(message)")
            } else if message == "Login cancelled" { onBack?() }
            else { showError("Failed to login to \(providerName): \(message)") }
        }
    }

    /// Refreshes a single provider's catalog without blocking the caller. Each call gets its own
    /// cancellation token, so a forced refresh never queues behind a stalled earlier one — the
    /// coordinator's per-provider generation guard supersedes-and-cancels the previous run
    /// (#7301, #7421).
    @MainActor
    private func refreshProviderCatalogInBackground(providerId: String, actionLabel: String, selectAfterLogin: Bool = false) {
        guard let session else { return }
        let modelAtStart = session.agent.state.model
        let selectionRevision = modelSelectionRevision
        Task { @MainActor [weak self] in
            let outcome = await runBoundedCatalogRefresh(
                registry: session.modelRegistry,
                providers: [providerId],
                signal: CancellationToken()
            )
            guard let self, self.session === session else { return }
            if let warning = CatalogRefreshStatus.authMessage(outcome, actionLabel: actionLabel) {
                self.showWarning(warning)
            }
            if selectAfterLogin,
               self.canApplyPostLoginSelection(session, previousModel: modelAtStart, revision: selectionRevision) {
                let available = await session.modelRegistry.getAvailable().filter { $0.provider == providerId }
                if let model = await selectDefaultModel(available: available, registry: session.modelRegistry) {
                    guard self.canApplyPostLoginSelection(session, previousModel: modelAtStart, revision: selectionRevision) else { return }
                    do {
                        try await session.setModel(model, options: ModelMutationOptions(persist: true))
                        self.updateEditorBorderColor()
                    } catch { self.showError(error.localizedDescription) }
                } else if self.canApplyPostLoginSelection(session, previousModel: modelAtStart, revision: selectionRevision) {
                    let detail = available.isEmpty
                        ? "no models are available for that provider"
                        : "its default model is not available"
                    self.showError("\(actionLabel), but \(detail). Use /model to select a model.")
                }
            } else {
                await session.refreshActiveModel()
            }
            self.footer?.invalidate()
            self.ui.requestRender()
        }
    }

    @MainActor
    private func handleShareCommand() async {
        guard let session, let tui, let editorContainer, let editor else { return }
        await shareSession(session: session, tui: tui, editorContainer: editorContainer, editor: editor,
                           showStatus: { [weak self] in self?.showStatus($0) },
                           showError: { [weak self] in self?.showError($0) })
    }

    @MainActor
    private func handleBugCommand(_ hint: String?) async {
        guard let session, let tui, let editorContainer, let editor else { return }
        let flow = BugReportUI(session: session, tui: tui, editorContainer: editorContainer, editor: editor,
                               showStatus: { [weak self] in self?.showStatus($0) },
                               showError: { [weak self] in self?.showError($0) })
        await flow.run(initialHint: hint)
    }

    @MainActor
    func announceSavedCrashIfNeeded() {
        guard let crash = crashLog.takeUnannounced() else { return }
        showWarning("Pi crashed during the previous session. Use /bug to export a report.")
        let paths = session?.resourceLoader.getExtensions().paths ?? []
        let extensions = paths.map { path in
            CrashExtension(label: URL(fileURLWithPath: path).lastPathComponent, dylibPath: path)
        }
        let matches = findExtensionStackMatches(crash.stack, extensions: extensions)
        if !matches.isEmpty {
            showWarning("The crash stack mentions loaded extensions: \(matches.joined(separator: ", "))")
        }
    }

    @MainActor
    func handleExportCommand(_ text: String) async {
        guard let session else { return }
        let parts = text.split(separator: " ").map(String.init)
        let outputPath = parts.count > 1 ? parts[1] : nil

        do {
            let exported = try outputPath?.hasSuffix(".jsonl") == true
                ? session.exportToJsonl(outputPath)
                : await session.exportToHtml(outputPath, themeName: theme.name)
            showStatus("Exported to: \(exported)")
        } catch {
            showError("Export failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func handleCopyCommand(preferSelection: Bool = false) {
        if preferSelection, tui?.mode == .altScreen, let renderer = altScreenRenderer,
           !renderer.getCopyOnSelect(), renderer.hasActiveSelection() {
            Task { @MainActor in _ = await renderer.copyActiveSelectionToClipboard() }
            return
        }
        guard let text = session?.getLastAssistantText()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            showError("No agent messages to copy yet.")
            return
        }

        switch clipboardCopy(text) {
        case .success:
            if tui?.mode == .altScreen {
                altScreenRenderer?.flash("Copied!")
            } else {
                showStatus("Copied last agent message to clipboard")
            }
        case .osc52SentUnverified:
            let notice = "Sent a copy request to the terminal; clipboard not verified"
            if tui?.mode == .altScreen {
                altScreenRenderer?.flash(notice, durationMilliseconds: 5_000)
            } else {
                showStatus(notice)
            }
        case .failure(let message):
            if tui?.mode == .altScreen {
                altScreenRenderer?.flash(message, durationMilliseconds: 5_000)
            }
            showError(message)
        }
    }

    @MainActor
    func handleSessionCommand() async {
        guard let session else { return }
        let entries = session.sessionManager.getEntries()
        let usageBreakdown = getUsageCostBreakdown(entries)
        let cacheWaste = computeCacheWaste(entries, modelRegistry: session.modelRegistry)
        let selectedModel = session.agent.state.model
        let selectedModelKey = "\(selectedModel.provider)/\(selectedModel.id)"
        let cacheWarmingStatus = await session.cacheWarmingStatus()
        let stats = session.getSessionStats()
        let sessionName = session.sessionManager.getSessionName()
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatNumber: (Int) -> String = { value in
            formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        let cacheWarmingMode = session.settingsManager.getCacheWarmingMode().rawValue
        let renderInfo = {
            var info = "\(theme.bold("Session Info"))\n\n"
            if let sessionName {
                info += "\(theme.fg(.dim, "Name:")) \(sessionName)\n"
            }
            info += "\(theme.fg(.dim, "File:")) \(stats.sessionFile ?? "In-memory")\n"
            info += "\(theme.fg(.dim, "ID:")) \(stats.sessionId)\n\n"
            info += "\(theme.bold("Messages"))\n"
            info += "\(theme.fg(.dim, "Total:")) \(stats.totalMessages)\n"
            info += "\(theme.fg(.dim, "User:")) \(stats.userMessages)\n"
            info += "\(theme.fg(.dim, "Assistant:")) \(stats.assistantMessages)\n"
            info += "\(theme.fg(.dim, "Tools:")) \(stats.toolCalls) calls, \(stats.toolResults) results\n\n"
            info += "\(theme.bold("Tokens"))\n"
            let promptTokens = stats.tokens.input + stats.tokens.cacheRead + stats.tokens.cacheWrite
            info += "\(theme.fg(.dim, "Input:")) \(formatNumber(promptTokens))\n"
            if promptTokens > 0 && (stats.tokens.cacheRead > 0 || stats.tokens.cacheWrite > 0) {
                let rate = theme.fg(.dim, String(format: "(%.1f%%)", Double(stats.tokens.cacheRead) / Double(promptTokens) * 100))
                info += "  \(theme.fg(.dim, "Cached:")) \(formatNumber(stats.tokens.cacheRead)) \(rate)\n"
                let written = stats.tokens.cacheWrite > 0 ? " " + theme.fg(.dim, "(\(formatNumber(stats.tokens.cacheWrite)) written to cache)") : ""
                info += "  \(theme.fg(.dim, "Uncached:")) \(formatNumber(stats.tokens.input + stats.tokens.cacheWrite))\(written)\n"
            }
            info += "\(theme.fg(.dim, "Output:")) \(formatNumber(stats.tokens.output))\n"
            info += "\(theme.fg(.dim, "Total:")) \(formatNumber(stats.tokens.total))\n"
            info += "\n\(theme.bold("Cache Warming"))\n"
            info += "\(theme.fg(.dim, "Mode:")) \(cacheWarmingMode)\n"
            info += "\(theme.fg(.dim, "Status:")) \(cacheWarmingStatus.map { formatCacheWarmingStatus($0) } ?? "Inactive (cache warming unavailable)")\n"
            if let decision = cacheWarmingStatus?.decision, decision.economicsAvailable {
                info += "\(theme.fg(.dim, "Cache miss penalty:")) $\(String(format: "%.3f", decision.missCost))\n"
                info += "\(theme.fg(.dim, "Refresh cost:")) $\(String(format: "%.3f", decision.warmCost))\n"
            }
            if stats.cost > 0 || cacheWaste.missedTokens > 0 {
                info += "\n\(theme.bold("Cost"))\n"
                info += "\(theme.fg(.dim, "Total:")) $\(String(format: "%.3f", stats.cost))"
                if usageBreakdown.count > 1 || usageBreakdown.first?.key != selectedModelKey {
                    for entry in usageBreakdown {
                        info += "\n  \(theme.fg(.dim, entry.key + ":")) $\(String(format: "%.3f", entry.cost)) \(theme.fg(.dim, "(\(formatTokens(entry.tokens)) tokens)"))"
                    }
                }
                if cacheWaste.missedTokens > 0 {
                    let missLabel = cacheWaste.missCount == 1 ? "1 miss" : "\(cacheWaste.missCount) misses"
                    let detail = "\(formatNumber(cacheWaste.missedTokens)) tokens, \(missLabel)"
                    info += "\n" + theme.fg(.dim, "Cache Re-billed:") + " "
                    info += cacheWaste.missedCost >= 0.0001
                        ? "$\(String(format: "%.3f", cacheWaste.missedCost)) " + theme.fg(.dim, "(\(detail))")
                        : detail
                }
            }

            return info
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText(renderInfo, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func handleFilesCommand() {
        guard let session else { return }
        var fileOps = createFileOps()
        let context = session.sessionManager.buildSessionContext()
        for message in context.messages {
            extractFileOpsFromMessage(message, &fileOps)
        }
        let lists = computeFileLists(fileOps)

        let renderInfo = {
            var info = "\(theme.bold("File Operations"))\n\n"
            if lists.readFiles.isEmpty && lists.modifiedFiles.isEmpty {
                info += theme.fg(.dim, "No file operations recorded.")
            } else {
                if !lists.readFiles.isEmpty {
                    info += "\(theme.bold("Read"))\n"
                    info += lists.readFiles.map { "  \($0)" }.joined(separator: "\n")
                    info += "\n\n"
                }
                if !lists.modifiedFiles.isEmpty {
                    info += "\(theme.bold("Modified"))\n"
                    info += lists.modifiedFiles.map { "  \($0)" }.joined(separator: "\n")
                }
            }

            return info
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText(renderInfo, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func handleNameCommand(_ text: String) {
        guard let session else { return }
        let stripped = text.replacingOccurrences(of: "^/name\\s*", with: "", options: .regularExpression)
        let name = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            if let currentName = session.sessionManager.getSessionName() {
                chatContainer.addChild(Spacer(1))
                chatContainer.addChild(ThemedText({ theme.fg(.dim, "Session name: \(currentName)") }, paddingX: 1, paddingY: 0))
            } else {
                showWarning("Usage: /name <name>")
            }
            scheduleRender()
            return
        }

        session.sessionManager.appendSessionInfo(name)
        updateTerminalTitle()
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.dim, "Session name set: \(name)") }, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func handleSkillCommand(skillPath: String, args: String) async {
        do {
            let content = try String(contentsOfFile: skillPath, encoding: .utf8)
            let body = content
                .replacingOccurrences(of: "^---\\n[\\s\\S]*?\\n---\\n", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = args.isEmpty ? body : "\(body)\n\n---\n\nUser: \(args)"
            await prompt(message, images: nil)
        } catch {
            showError("Failed to load skill: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleChangelogCommand() {
        let path = getChangelogPath()
        let entries = parseChangelog(path)
        let changelogMarkdown: String
        if entries.isEmpty {
            changelogMarkdown = "No changelog entries found."
        } else {
            changelogMarkdown = entries.reversed().map { $0.content }.joined(separator: "\n\n")
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(DynamicBorder())
        chatContainer.addChild(ThemedText({ theme.bold(theme.fg(.accent, "What's New")) }, paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Markdown(changelogMarkdown, paddingX: 1, paddingY: 1, theme: getMarkdownTheme()))
        chatContainer.addChild(DynamicBorder())
        scheduleRender()
    }

    @MainActor
    func handleHotkeysCommand() {
        let cursorWordLeft = getEditorKeyDisplay(.cursorWordLeft)
        let cursorWordRight = getEditorKeyDisplay(.cursorWordRight)
        let cursorLineStart = getEditorKeyDisplay(.cursorLineStart)
        let cursorLineEnd = getEditorKeyDisplay(.cursorLineEnd)

        let submit = getEditorKeyDisplay(.submit)
        let newLine = getEditorKeyDisplay(.newLine)
        let deleteWordBackward = getEditorKeyDisplay(.deleteWordBackward)
        let deleteToLineStart = getEditorKeyDisplay(.deleteToLineStart)
        let deleteToLineEnd = getEditorKeyDisplay(.deleteToLineEnd)
        let tab = getEditorKeyDisplay(.tab)

        let interrupt = getAppKeyDisplay(.interrupt)
        let clear = getAppKeyDisplay(.clear)
        let exit = getAppKeyDisplay(.exit)
        let suspend = getAppKeyDisplay(.suspend)
        let cycleThinkingLevel = getAppKeyDisplay(.cycleThinkingLevel)
        let cycleModelForward = getAppKeyDisplay(.cycleModelForward)
        let expandTools = getAppKeyDisplay(.expandTools)
        let toggleThinking = getAppKeyDisplay(.toggleThinking)
        let externalEditor = getAppKeyDisplay(.externalEditor)
        let followUp = getAppKeyDisplay(.followUp)
        let dequeue = getAppKeyDisplay(.dequeue)
        let copyMessage = getAppKeyDisplay(.copyMessage)

        var hotkeys = """
**Navigation**
| Key | Action |
|-----|--------|
| `Arrow keys` | Move cursor / browse history (Up when empty) |
| `\(cursorWordLeft)` / `\(cursorWordRight)` | Move by word |
| `\(cursorLineStart)` | Start of line |
| `\(cursorLineEnd)` | End of line |

**Editing**
| Key | Action |
|-----|--------|
| `\(submit)` | Send message |
| `\(newLine)` | New line |
| `\(deleteWordBackward)` | Delete word backwards |
| `\(deleteToLineStart)` | Delete to start of line |
| `\(deleteToLineEnd)` | Delete to end of line |

**Other**
| Key | Action |
|-----|--------|
| `\(tab)` | Path completion / accept autocomplete |
| `\(interrupt)` | Cancel autocomplete / abort streaming |
| `\(clear)` | Clear editor (first) / exit (second) |
| `\(exit)` | Exit (when editor is empty) |
| `\(suspend)` | Suspend to background |
| `\(cycleThinkingLevel)` | Cycle thinking level |
| `\(cycleModelForward)` | Cycle models |
| `\(expandTools)` | Toggle tool output expansion |
| `\(toggleThinking)` | Toggle thinking block visibility |
| `\(externalEditor)` | Edit message in external editor |
| `\(followUp)` | Queue follow-up message |
| `\(dequeue)` | Restore queued messages |
| `\(copyMessage)` | Copy selection or last assistant message |
| `Ctrl+V` | Paste files on macOS, images, or text from clipboard |
| `/` | Slash commands |
| `!` | Run bash command |
"""

        if !hookShortcuts.isEmpty {
            hotkeys += """

**Hooks**
| Key | Action |
|-----|--------|
"""
            let sorted = hookShortcuts.keys.sorted()
            for key in sorted {
                if let shortcut = hookShortcuts[key] {
                    let description = shortcut.description ?? shortcut.hookPath
                    hotkeys += "| `\(key)` | \(description) |\n"
                }
            }
        }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(DynamicBorder())
        chatContainer.addChild(ThemedText({ theme.bold(theme.fg(.accent, "Keyboard Shortcuts")) }, paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Markdown(hotkeys.trimmingCharacters(in: .whitespacesAndNewlines), paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
        chatContainer.addChild(DynamicBorder())
        scheduleRender()
    }

    @MainActor
    private func handleTemplatesCommand() {
        guard let session else { return }
        let templates = session.promptTemplates.sorted { $0.name.lowercased() < $1.name.lowercased() }

        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.bold(theme.fg(.accent, "Prompt Templates")) }, paddingX: 1, paddingY: 0))
        chatContainer.addChild(Spacer(1))

        if templates.isEmpty {
            chatContainer.addChild(ThemedText({ theme.fg(.dim, "No prompt templates found") }, paddingX: 1, paddingY: 0))
            scheduleRender()
            return
        }

        let list = templates
            .map { "- /\($0.name) - \($0.description)" }
            .joined(separator: "\n")
        chatContainer.addChild(Markdown(list, paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
        scheduleRender()
    }

    /// Refresh host state after the session reads settings and replaces extension tools.
    @MainActor
    private func refreshHostSettingsAfterReload() {
        guard let session, let tui else { return }
        let settings = session.settingsManager
        let next = InteractiveTuiConfiguration(settingsManager: settings, modeOverride: tuiModeOverride)
        let currentMode = tuiConfiguration.mode
        tuiConfiguration = next
        tuiConfiguration.mode = currentMode
        if next.mode != currentMode { _ = switchTuiMode(next.mode) }
        setFullscreenScrollbar(next.scrollbar)
        setFullscreenWheelScrollLines(next.fullscreenWheelScrollLines)
        applyInteractiveTerminalCapabilities(settings)
        tui.setClearOnShrink(settings.getClearOnShrink())
        altScreenRenderer?.setCopyOnSelect(settings.getFullscreenCopyOnSelect())
        defaultEditor?.setPaddingX(settings.getEditorPaddingX())
        editor?.setPaddingX(settings.getEditorPaddingX())
        defaultEditor?.setAutocompleteMaxVisible(settings.getAutocompleteMaxVisible())
        editor?.setAutocompleteMaxVisible(settings.getAutocompleteMaxVisible())
        hideThinkingBlock = settings.getHideThinkingBlock()
        updateToolImages(settings.getShowImages())
        footer?.setAutoCompactEnabled(settings.getCompactionEnabled())
        themeController?.applyFromSettings()
        // Image resize/block, quiet startup, and skill settings are read at each use.
        // renderInitialMessages and rebuildAutocomplete below read their new values.
    }

    @MainActor
    func handleReloadCommand() async {
        guard let session, let tui, let editorContainer, let currentEditor = editor else { return }
        if session.isStreaming {
            showWarning("Wait for the current response to finish before reloading.")
            return
        }
        if session.isCompacting {
            showWarning("Wait for compaction to finish before reloading.")
            return
        }

        let loader = BorderedLoader(tui: tui, theme: theme, message: "Reloading skills, prompts, themes, extensions...")
        let previousEditor = currentEditor

        editorContainer.clear()
        editorContainer.addChild(loader)
        tui.setFocus(loader)
        ui.requestRender()

        let restoreEditor: @MainActor (EditorComponentView) -> Void = { editor in
            loader.dispose()
            editorContainer.clear()
            editorContainer.addChild(editor)
            tui.setFocus(editor)
            self.ui.requestRender()
        }

        await session.reload()
        let extensionResult = await session.reloadExtensions()
        refreshHostSettingsAfterReload()
        setWorkingMessage(nil)
        workingVisible = true
        setWorkingIndicator(nil)
        setHiddenThinkingLabel(nil)
        autocompleteProviderWrappers.removeAll()
        keybindings = KeybindingsManager.create()
        skills = session.resourceLoader.getSkills().skills
        setRegisteredThemes(session.resourceLoader.getThemes().themes)
        refreshStartupHeader()

        // Refresh hook-derived UI state so dropped extensions disappear and freshly-loaded
        // ones become reachable. setupHookShortcuts replaces the entire shortcut map.
        if let hookRunner = session.hookRunner {
            setupHookShortcuts(hookRunner)
        }
        rebuildAutocomplete()

        for error in extensionResult.errors {
            showHookError("extension", error.errorDescription ?? "\(error)")
        }

        pendingResourceDisplayOptions = ResourceDisplayOptions(
            extensionPaths: visibleStartupExtensionPaths(session.resourceLoader.getExtensions().paths),
            force: true
        )
        chatContainer.clear()
        renderInitialMessages()
        restoreEditor(previousEditor)

        let extDelta = extensionResult.loadedPaths.count - extensionResult.droppedPaths.count
        let extSummary: String
        if extensionResult.loadedPaths.isEmpty && extensionResult.droppedPaths.isEmpty {
            extSummary = ""
        } else if extDelta == 0 {
            extSummary = ", \(extensionResult.loadedPaths.count) extension\(extensionResult.loadedPaths.count == 1 ? "" : "s") refreshed"
        } else if extDelta > 0 {
            extSummary = ", +\(extDelta) extension\(extDelta == 1 ? "" : "s")"
        } else {
            extSummary = ", \(extDelta) extension\(extDelta == -1 ? "" : "s")"
        }
        showStatus("Reloaded skills, prompts, themes, keybindings\(extSummary)")
    }

    private func formatKeyDisplay(_ keys: [KeyId]) -> String {
        return keys.map { formatKeyDisplay($0) }.joined(separator: "/")
    }

    private func formatKeyDisplay(_ keys: String) -> String {
        return keys.split(separator: "+").map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: "+")
    }

    private func getAppKeyDisplay(_ action: AppAction) -> String {
        return formatKeyDisplay(keybindings.getDisplayString(action))
    }

    private func getEditorKeyDisplay(_ action: EditorAction) -> String {
        return formatKeyDisplay(getKeybindings().getKeys(action.keybinding))
    }

    @MainActor
    func handleNewSessionCommand() {
        guard let session else { return }
        _ = session.sessionManager.newSession()
        session.refreshContext()
        reportingManualCompaction = false
        programStatus.reset()
        altScreenRenderer?.resetTextSelection()
        chatContainer.clear()
        showStatus("New session started")
        scheduleRender()
    }

    /// v0.68.0: /clone — duplicate the current branch into a new session at the latest
    /// position. Distinct from /fork (forks BEFORE a chosen previous user message).
    @MainActor
    private func handleCloneCommand() {
        guard let session else { return }
        Task {
            do {
                let success = try await session.cloneAtLeaf()
                if success {
                    reportingManualCompaction = false
                    programStatus.reset()
                    chatContainer.clear()
                    renderInitialMessages()
                    showStatus("Cloned to new session")
                    scheduleRender()
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @MainActor
    func handleCompactCommand(_ customInstructions: String?) {
        guard let session else { return }
        loadingAnimation?.stop()
        loadingAnimation = nil
        clearWorkingIndicator()
        if session.settingsManager.getShowTerminalProgress() { tui?.terminal.setProgress(true) }
        reportingManualCompaction = true
        programStatus.handleEvent(.compactionStart)
        showStatus("Compacting...")
        setTransientStatus("Compacting")
        Task { @MainActor in
            defer { tui?.terminal.setProgress(false); setTransientStatus(nil) }
            do {
                _ = try await session.compact(customInstructions: customInstructions)
                finishManualCompactionReporting(aborted: false, errorMessage: nil)
                var entries = interactiveContextEntries(session.sessionManager)
                if let first = entries.first, case .compaction = first {
                    entries.removeFirst()
                    entries.append(first)
                }
                renderInitialMessages(entries: entries)
                showStatus("Compaction complete")
            } catch {
                let aborted: Bool
                if case AgentSessionError.compactionCancelled = error { aborted = true }
                else { aborted = error is CancellationError }
                finishManualCompactionReporting(aborted: aborted, errorMessage: aborted ? nil : "Compaction failed: \(error.localizedDescription)")
                showError(error.localizedDescription)
            }
        }
    }

    private func finishManualCompactionReporting(aborted: Bool, errorMessage: String?) {
        // End any earlier run while compaction still has status priority. Then report its result.
        programStatus.handleEvent(ProgramStatusInput.agentSettled(aborted: true))
        programStatus.handleEvent(.compactionEnd(manual: true, aborted: aborted, errorMessage: errorMessage))
    }

    @MainActor
    private func handleDebugCommand() {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(Text(getThemeDiagnostics(), paddingX: 1, paddingY: 0))
        let sample = { [
            "Color sample:",
            theme.fg(.accent, "accent"),
            theme.fg(.muted, "muted"),
            theme.bg(.selectedBg, " selectedBg "),
        ].joined(separator: " ") }
        chatContainer.addChild(ThemedText(sample, paddingX: 1, paddingY: 0))
        scheduleRender()
    }

    @MainActor
    private func updateToolImages(_ showImages: Bool) {
        for child in chatContainer.children {
            if let tool = child as? ToolExecutionComponent {
                tool.setShowImages(showImages)
            }
        }
        scheduleRender()
    }

    public func showStatus(_ message: String) {
        let children = chatContainer.children
        let last = children.last
        let secondLast = children.count > 1 ? children[children.count - 2] : nil

        if let last = last as? Text,
           let secondLast = secondLast as? Spacer,
           lastStatusText === last,
           lastStatusSpacer === secondLast {
            lastStatusMessage = message
            last.invalidate()
            ui.requestRender()
            return
        }

        let spacer = Spacer(1)
        lastStatusMessage = message
        let text = ThemedText({ [weak self] in theme.fg(.dim, self?.lastStatusMessage ?? message) }, paddingX: 1, paddingY: 0)
        chatContainer.addChild(spacer)
        chatContainer.addChild(text)
        lastStatusSpacer = spacer
        lastStatusText = text
        ui.requestRender()
    }

    public func showError(_ errorMessage: String) {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({
            theme.fg(.error, "Error: \(errorMessage)") },
            paddingX: tuiConfiguration.outputPad,
            paddingY: 0
        ))
        scheduleRender()
    }

    public func showWarning(_ warningMessage: String) {
        chatContainer.addChild(Spacer(1))
        chatContainer.addChild(ThemedText({ theme.fg(.warning, "Warning: \(warningMessage)") }, paddingX: 1, paddingY: 0))
        scheduleRender()
    }
}

private func decodeBashExecutionMessage(_ custom: AgentCustomMessage) -> BashExecutionMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let command = payload["command"] as? String ?? ""
    let output = payload["output"] as? String ?? ""
    let exitCode = payload["exitCode"] as? Int
    let cancelled = payload["cancelled"] as? Bool ?? false
    let truncated = payload["truncated"] as? Bool ?? false
    let fullOutputPath = payload["fullOutputPath"] as? String
    return BashExecutionMessage(command: command, output: output, exitCode: exitCode, cancelled: cancelled, truncated: truncated, fullOutputPath: fullOutputPath, timestamp: custom.timestamp, excludeFromContext: payload["excludeFromContext"] as? Bool)
}

private func decodeBranchSummaryMessage(_ custom: AgentCustomMessage) -> BranchSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let fromId = payload["fromId"] as? String ?? ""
    return BranchSummaryMessage(summary: summary, fromId: fromId, timestamp: custom.timestamp)
}

private func decodeCompactionSummaryMessage(_ custom: AgentCustomMessage) -> CompactionSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let tokensBefore = payload["tokensBefore"] as? Int ?? 0
    return CompactionSummaryMessage(summary: summary, tokensBefore: tokensBefore, timestamp: custom.timestamp)
}

private func decodeHookMessage(_ custom: AgentCustomMessage) -> HookMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    guard let customType = payload["customType"] as? String else { return nil }
    let display = payload["display"] as? Bool ?? true

    if let text = payload["content"] as? String {
        return HookMessage(customType: customType, content: .text(text), display: display, details: nil, timestamp: custom.timestamp)
    }

    if let blocks = payload["content"] as? [[String: Any]] {
        let contentBlocks: [ContentBlock] = blocks.compactMap { block in
            if let type = block["type"] as? String, type == "text", let text = block["text"] as? String {
                return .text(TextContent(text: text))
            }
            return nil
        }
        return HookMessage(customType: customType, content: .blocks(contentBlocks), display: display, details: nil, timestamp: custom.timestamp)
    }

    return HookMessage(customType: customType, content: .text(""), display: display, details: nil, timestamp: custom.timestamp)
}

private func settingsManagerCacheMisses(_ session: AgentSession, entries: [SessionEntry]) -> [String: CacheMiss] {
    guard session.settingsManager.getShowCacheMissNotices() else { return [:] }
    return collectCacheMisses(entries, modelRegistry: session.modelRegistry)
}

private func formatCacheMissNotice(_ miss: CacheMiss) -> String {
    let tokenText = NumberFormatter.localizedString(from: NSNumber(value: miss.missedTokens), number: .decimal)
    let reason = miss.modelChanged ? " after a model change" : miss.idleMs > CACHE_TTL_MS ? " after cache expiry" : ""
    if miss.missedCost > 0 {
        return "[Prompt cache miss] " + tokenText + " tokens re-billed (~$" + String(format: "%.4f", miss.missedCost) + ")" + reason
    }
    return "[Prompt cache miss] " + tokenText + " tokens re-billed" + reason
}
