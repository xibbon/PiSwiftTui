import Foundation
import MiniTui
import PiSwiftAgent
import PiSwiftAI
import PiSwiftCodingAgent

let thinkingDescriptions: [ThinkingLevel: String] = [
    .off: "No reasoning",
    .minimal: "Very brief reasoning (~1k tokens)",
    .low: "Light reasoning (~2k tokens)",
    .medium: "Moderate reasoning (~8k tokens)",
    .high: "Deep reasoning (~16k tokens)",
    .xhigh: "Extra-high reasoning (~32k tokens)",
    .max: "Maximum reasoning",
]

public struct SettingsConfig: Sendable {
    public var autoCompact: Bool
    public var showImages: Bool
    public var autoResizeImages: Bool
    public var blockImages: Bool
    public var enableSkillCommands: Bool
    public var steeringMode: String
    public var followUpMode: String
    public var transport: Transport
    public var thinkingLevel: ThinkingLevel
    public var availableThinkingLevels: [ThinkingLevel]
    public var currentTheme: String
    public var availableThemes: [String]
    public var hideThinkingBlock: Bool
    public var showCacheMissNotices: Bool
    public var collapseChangelog: Bool
    public var quietStartup: Bool
    public var doubleEscapeAction: String
    public var editorPaddingX: Int
    public var autocompleteMaxVisible: Int
    public var tuiMode: InteractiveTuiMode
    public var fullscreenScrollbar: FullscreenScrollbarMode
    public var mouseWheelStep: Int
    public var mermaidEnabled: Bool
    public var mermaidRenderWhileStreaming: Bool
    public var latexEnabled: Bool
    public var outputPad: Int
    public var defaultModel: String
    public var currentModel: Model?
    public var availableDefaultModels: [Model]
    public var modelThinkingLevels: [String: ThinkingLevel]
    public var fullscreenExitOutput: FullscreenExitOutput
    public var thinkingCycleKey: String
    public var terminalTheme: TerminalColorScheme
    public var fullscreenCopyOnSelect: Bool

    public init(
        autoCompact: Bool,
        showImages: Bool,
        autoResizeImages: Bool,
        blockImages: Bool,
        enableSkillCommands: Bool,
        steeringMode: String,
        followUpMode: String,
        transport: Transport,
        thinkingLevel: ThinkingLevel,
        availableThinkingLevels: [ThinkingLevel],
        currentTheme: String,
        availableThemes: [String],
        hideThinkingBlock: Bool,
        showCacheMissNotices: Bool,
        collapseChangelog: Bool,
        quietStartup: Bool,
        doubleEscapeAction: String,
        editorPaddingX: Int,
        autocompleteMaxVisible: Int,
        tuiMode: InteractiveTuiMode,
        fullscreenScrollbar: FullscreenScrollbarMode,
        mouseWheelStep: Int,
        mermaidEnabled: Bool,
        mermaidRenderWhileStreaming: Bool,
        latexEnabled: Bool,
        outputPad: Int,
        defaultModel: String = "not set",
        currentModel: Model? = nil,
        availableDefaultModels: [Model] = [],
        modelThinkingLevels: [String: ThinkingLevel] = [:],
        fullscreenExitOutput: FullscreenExitOutput = .transcript,
        fullscreenCopyOnSelect: Bool = true,
        terminalTheme: TerminalColorScheme = .dark,
        thinkingCycleKey: String = "Shift+Tab"
    ) {
        self.autoCompact = autoCompact
        self.showImages = showImages
        self.autoResizeImages = autoResizeImages
        self.blockImages = blockImages
        self.enableSkillCommands = enableSkillCommands
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.transport = transport
        self.thinkingLevel = thinkingLevel
        self.availableThinkingLevels = availableThinkingLevels
        self.currentTheme = currentTheme
        self.availableThemes = availableThemes
        self.hideThinkingBlock = hideThinkingBlock
        self.showCacheMissNotices = showCacheMissNotices
        self.collapseChangelog = collapseChangelog
        self.quietStartup = quietStartup
        self.doubleEscapeAction = doubleEscapeAction
        self.editorPaddingX = editorPaddingX
        self.autocompleteMaxVisible = autocompleteMaxVisible
        self.tuiMode = tuiMode
        self.fullscreenScrollbar = fullscreenScrollbar
        self.mouseWheelStep = mouseWheelStep
        self.mermaidEnabled = mermaidEnabled
        self.mermaidRenderWhileStreaming = mermaidRenderWhileStreaming
        self.latexEnabled = latexEnabled
        self.outputPad = outputPad
        self.defaultModel = defaultModel
        self.currentModel = currentModel
        self.availableDefaultModels = availableDefaultModels
        self.modelThinkingLevels = modelThinkingLevels
        self.fullscreenExitOutput = fullscreenExitOutput
        self.fullscreenCopyOnSelect = fullscreenCopyOnSelect
        self.terminalTheme = terminalTheme
        self.thinkingCycleKey = thinkingCycleKey
    }
}

public struct SettingsCallbacks {
    public var onAutoCompactChange: (Bool) -> Void
    public var onShowImagesChange: (Bool) -> Void
    public var onAutoResizeImagesChange: (Bool) -> Void
    public var onBlockImagesChange: (Bool) -> Void
    public var onEnableSkillCommandsChange: (Bool) -> Void
    public var onSteeringModeChange: (String) -> Void
    public var onFollowUpModeChange: (String) -> Void
    public var onTransportChange: (Transport) -> Void
    public var onThinkingLevelChange: (ThinkingLevel) -> Void
    public var onThemeChange: (String) -> Void
    public var onThemePreview: ((String) -> Void)?
    public var onHideThinkingBlockChange: (Bool) -> Void
    public var onShowCacheMissNoticesChange: (Bool) -> Void
    public var onCollapseChangelogChange: (Bool) -> Void
    public var onQuietStartupChange: (Bool) -> Void
    public var onDoubleEscapeActionChange: (String) -> Void
    public var onEditorPaddingXChange: (Int) -> Void
    public var onAutocompleteMaxVisibleChange: (Int) -> Void
    public var onTuiModeChange: (InteractiveTuiMode) -> Void
    public var onFullscreenScrollbarChange: (FullscreenScrollbarMode) -> Void
    public var onMouseWheelStepChange: (Int) -> Void
    public var onMermaidEnabledChange: (Bool) -> Void
    public var onMermaidRenderWhileStreamingChange: (Bool) -> Void
    public var onLatexEnabledChange: (Bool) -> Void
    public var onOutputPadChange: (Int) -> Void
    public var onModelThinkingLevelChange: (String, String, ThinkingLevel) -> Void
    public var onModelThinkingLevelRemove: (String, String) -> Void
    public var onFullscreenExitOutputChange: (FullscreenExitOutput) -> Void
    public var onFullscreenCopyOnSelectChange: (Bool) -> Void
    public var onCancel: () -> Void

    public init(
        onAutoCompactChange: @escaping (Bool) -> Void,
        onShowImagesChange: @escaping (Bool) -> Void,
        onAutoResizeImagesChange: @escaping (Bool) -> Void,
        onBlockImagesChange: @escaping (Bool) -> Void,
        onEnableSkillCommandsChange: @escaping (Bool) -> Void,
        onSteeringModeChange: @escaping (String) -> Void,
        onFollowUpModeChange: @escaping (String) -> Void,
        onTransportChange: @escaping (Transport) -> Void,
        onThinkingLevelChange: @escaping (ThinkingLevel) -> Void,
        onThemeChange: @escaping (String) -> Void,
        onThemePreview: ((String) -> Void)? = nil,
        onHideThinkingBlockChange: @escaping (Bool) -> Void,
        onShowCacheMissNoticesChange: @escaping (Bool) -> Void,
        onCollapseChangelogChange: @escaping (Bool) -> Void,
        onQuietStartupChange: @escaping (Bool) -> Void,
        onDoubleEscapeActionChange: @escaping (String) -> Void,
        onEditorPaddingXChange: @escaping (Int) -> Void,
        onAutocompleteMaxVisibleChange: @escaping (Int) -> Void,
        onTuiModeChange: @escaping (InteractiveTuiMode) -> Void,
        onFullscreenScrollbarChange: @escaping (FullscreenScrollbarMode) -> Void,
        onMouseWheelStepChange: @escaping (Int) -> Void,
        onMermaidEnabledChange: @escaping (Bool) -> Void,
        onMermaidRenderWhileStreamingChange: @escaping (Bool) -> Void,
        onLatexEnabledChange: @escaping (Bool) -> Void,
        onOutputPadChange: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void,
        onModelThinkingLevelChange: @escaping (String, String, ThinkingLevel) -> Void = { _, _, _ in },
        onModelThinkingLevelRemove: @escaping (String, String) -> Void = { _, _ in },
        onFullscreenExitOutputChange: @escaping (FullscreenExitOutput) -> Void = { _ in },
        onFullscreenCopyOnSelectChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onAutoCompactChange = onAutoCompactChange
        self.onShowImagesChange = onShowImagesChange
        self.onAutoResizeImagesChange = onAutoResizeImagesChange
        self.onBlockImagesChange = onBlockImagesChange
        self.onEnableSkillCommandsChange = onEnableSkillCommandsChange
        self.onSteeringModeChange = onSteeringModeChange
        self.onFollowUpModeChange = onFollowUpModeChange
        self.onTransportChange = onTransportChange
        self.onThinkingLevelChange = onThinkingLevelChange
        self.onThemeChange = onThemeChange
        self.onThemePreview = onThemePreview
        self.onHideThinkingBlockChange = onHideThinkingBlockChange
        self.onShowCacheMissNoticesChange = onShowCacheMissNoticesChange
        self.onCollapseChangelogChange = onCollapseChangelogChange
        self.onQuietStartupChange = onQuietStartupChange
        self.onDoubleEscapeActionChange = onDoubleEscapeActionChange
        self.onEditorPaddingXChange = onEditorPaddingXChange
        self.onAutocompleteMaxVisibleChange = onAutocompleteMaxVisibleChange
        self.onTuiModeChange = onTuiModeChange
        self.onFullscreenScrollbarChange = onFullscreenScrollbarChange
        self.onMouseWheelStepChange = onMouseWheelStepChange
        self.onMermaidEnabledChange = onMermaidEnabledChange
        self.onMermaidRenderWhileStreamingChange = onMermaidRenderWhileStreamingChange
        self.onLatexEnabledChange = onLatexEnabledChange
        self.onOutputPadChange = onOutputPadChange
        self.onCancel = onCancel
        self.onModelThinkingLevelChange = onModelThinkingLevelChange
        self.onModelThinkingLevelRemove = onModelThinkingLevelRemove
        self.onFullscreenExitOutputChange = onFullscreenExitOutputChange
        self.onFullscreenCopyOnSelectChange = onFullscreenCopyOnSelectChange
    }
}

@MainActor
private final class SettingsSubmenuState { var isOpen = false }

public final class SettingsSelectorComponent: Container, MouseFocusOwner, SystemCursorAware {
    private let submenuState: SettingsSubmenuState
    private let settingsList: SettingsList
    public var usesSystemCursor: Bool = false {
        didSet { settingsList.usesSystemCursor = usesSystemCursor }
    }

    public init(config: SettingsConfig, callbacks: SettingsCallbacks) {
        let submenuState = SettingsSubmenuState()
        self.submenuState = submenuState
        let overrideState = ModelThinkingOverrideState(config.modelThinkingLevels)
        let supportsImages = getCapabilities().images != nil

        var items: [SettingItem] = [
            SettingItem(
                id: "autocompact",
                label: "Auto-compact",
                description: "Automatically compact context when it gets too large",
                currentValue: config.autoCompact ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "steering-mode",
                label: "Steering mode",
                description: "Enter while streaming queues steering messages. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.",
                currentValue: config.steeringMode,
                values: ["one-at-a-time", "all"]
            ),
            SettingItem(
                id: "follow-up-mode",
                label: "Follow-up mode",
                description: "Alt+Enter queues follow-up messages until agent stops. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.",
                currentValue: config.followUpMode,
                values: ["one-at-a-time", "all"]
            ),
            SettingItem(
                id: "transport",
                label: "Transport",
                description: "Preferred transport for providers that support multiple transports",
                currentValue: config.transport.rawValue,
                values: ["sse", "websocket", "auto"]
            ),
            SettingItem(
                id: "hide-thinking",
                label: "Hide thinking",
                description: "Hide thinking blocks in assistant responses",
                currentValue: config.hideThinkingBlock ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "show-cache-miss-notices",
                label: "Show cache miss notices",
                description: "Show transcript notices for cache costs and provider recovery diagnostics",
                currentValue: config.showCacheMissNotices ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "collapse-changelog",
                label: "Collapse changelog",
                description: "Show condensed changelog after updates",
                currentValue: config.collapseChangelog ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "quiet-startup",
                label: "Quiet startup",
                description: "Disable verbose printing at startup",
                currentValue: config.quietStartup ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "double-escape-action",
                label: "Double-escape action",
                description: "Action when pressing Escape twice with empty editor",
                currentValue: config.doubleEscapeAction,
                values: ["tree", "fork", "none"]
            ),
            SettingItem(
                id: "autocomplete-max-visible",
                label: "Autocomplete max items",
                description: "Max visible items in autocomplete dropdown (3-20)",
                currentValue: String(config.autocompleteMaxVisible),
                values: ["3", "5", "7", "10", "15", "20"]
            ),
            SettingItem(
                id: "tui-mode",
                label: "TUI mode",
                description: "Interface layout; fullscreen mode is experimental",
                currentValue: config.tuiMode.rawValue,
                values: InteractiveTuiMode.allCases.map(\.rawValue)
            ),
            SettingItem(
                id: "fullscreen-scrollbar",
                label: "Fullscreen scrollbar",
                description: "Scrollbar behavior in fullscreen mode",
                currentValue: config.fullscreenScrollbar.rawValue,
                values: FullscreenScrollbarMode.allCases.map(\.rawValue)
            ),
            SettingItem(
                id: "mouse-wheel-step",
                label: "Mouse wheel step",
                description: "Lines scrolled for each mouse wheel event",
                currentValue: String(config.mouseWheelStep),
                values: ["1", "3", "5", "10"]
            ),
            SettingItem(
                id: "mermaid-enabled",
                label: "Mermaid diagrams",
                description: "Render supported Mermaid diagrams as themed Unicode",
                currentValue: config.mermaidEnabled ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "mermaid-streaming",
                label: "Mermaid while streaming",
                description: "Render Mermaid diagrams before the response is complete",
                currentValue: config.mermaidRenderWhileStreaming ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "latex-enabled",
                label: "LaTeX rendering",
                description: "Render supported LaTeX expressions as Unicode",
                currentValue: config.latexEnabled ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "editor-padding-x",
                label: "Editor padding",
                description: "Horizontal padding inside the prompt editor (0-3)",
                currentValue: String(config.editorPaddingX),
                values: ["0", "1", "2", "3"]
            ),
            SettingItem(
                id: "output-padding",
                label: "Output padding",
                description: "Horizontal padding for chat messages and errors",
                currentValue: String(config.outputPad),
                values: ["0", "1"]
            ),
            SettingItem(
                id: "model-thinking",
                label: "Default thinking level per model",
                description: "Override the default thinking level for specific models. \(config.thinkingCycleKey) cycles in-session.",
                currentValue: overrideState.summary,
                submenu: { _, done in
                    submenuState.isOpen = true
                    return makeModelThinkingSubmenu(config: config, callbacks: callbacks, state: overrideState, done: { value in
                        submenuState.isOpen = false
                        done(value)
                    })
                }
            ),
            SettingItem(
                id: "fullscreen-exit-output",
                label: "Fullscreen exit output",
                description: "Print the transcript or only a session resume hint when exiting fullscreen mode",
                currentValue: config.fullscreenExitOutput.rawValue,
                values: ["transcript", "resume-hint"]
            ),
            SettingItem(
                id: "fullscreen-copy-on-select",
                label: "Fullscreen copy on select",
                description: "Automatically copy selected text in fullscreen mode; disable to copy selections with Ctrl+X",
                currentValue: config.fullscreenCopyOnSelect ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "theme",
                label: "Theme",
                description: "Color theme for the interface",
                currentValue: config.currentTheme,
                submenu: { currentValue, done in
                    submenuState.isOpen = true
                    return ThemeSettingsSubmenu(currentTheme: currentValue, terminalTheme: config.terminalTheme,
                        availableThemes: config.availableThemes, callbacks: callbacks, done: { value in
                            submenuState.isOpen = false
                            if let value { callbacks.onThemeChange(value) }
                            done(value)
                        })
                }
            ),
        ]

        if supportsImages {
            items.insert(
                SettingItem(
                    id: "show-images",
                    label: "Show images",
                    description: "Render images inline in terminal",
                    currentValue: config.showImages ? "true" : "false",
                    values: ["true", "false"]
                ),
                at: 1
            )
        }

        let autoResizeIndex = supportsImages ? 2 : 1
        items.insert(
            SettingItem(
                id: "auto-resize-images",
                label: "Auto-resize images",
                description: "Resize large images to 2000x2000 max for better model compatibility",
                currentValue: config.autoResizeImages ? "true" : "false",
                values: ["true", "false"]
            ),
            at: autoResizeIndex
        )

        let blockImagesIndex = autoResizeIndex + 1
        items.insert(
            SettingItem(
                id: "block-images",
                label: "Block images",
                description: "Prevent images from being sent to LLM providers",
                currentValue: config.blockImages ? "true" : "false",
                values: ["true", "false"]
            ),
            at: blockImagesIndex
        )

        let skillCommandsIndex = blockImagesIndex + 1
        items.insert(
            SettingItem(
                id: "skill-commands",
                label: "Skill commands",
                description: "Register skills as /skill:name commands",
                currentValue: config.enableSkillCommands ? "true" : "false",
                values: ["true", "false"]
            ),
            at: skillCommandsIndex
        )

        self.settingsList = SettingsList(
            items: items,
            maxVisible: 10,
            theme: getSettingsListTheme(),
            onChange: { id, newValue in
                switch id {
                case "autocompact":
                    callbacks.onAutoCompactChange(newValue == "true")
                case "show-images":
                    callbacks.onShowImagesChange(newValue == "true")
                case "auto-resize-images":
                    callbacks.onAutoResizeImagesChange(newValue == "true")
                case "block-images":
                    callbacks.onBlockImagesChange(newValue == "true")
                case "skill-commands":
                    callbacks.onEnableSkillCommandsChange(newValue == "true")
                case "steering-mode":
                    callbacks.onSteeringModeChange(newValue)
                case "follow-up-mode":
                    callbacks.onFollowUpModeChange(newValue)
                case "transport":
                    if let transport = Transport(rawValue: newValue) {
                        callbacks.onTransportChange(transport)
                    }
                case "hide-thinking":
                    callbacks.onHideThinkingBlockChange(newValue == "true")
                case "show-cache-miss-notices":
                    callbacks.onShowCacheMissNoticesChange(newValue == "true")
                case "collapse-changelog":
                    callbacks.onCollapseChangelogChange(newValue == "true")
                case "quiet-startup":
                    callbacks.onQuietStartupChange(newValue == "true")
                case "double-escape-action":
                    callbacks.onDoubleEscapeActionChange(newValue)
                case "editor-padding-x":
                    if let value = Int(newValue) {
                        callbacks.onEditorPaddingXChange(value)
                    }
                case "autocomplete-max-visible":
                    if let value = Int(newValue) {
                        callbacks.onAutocompleteMaxVisibleChange(value)
                    }
                case "tui-mode":
                    if let value = InteractiveTuiMode(rawValue: newValue) {
                        callbacks.onTuiModeChange(value)
                    }
                case "fullscreen-scrollbar":
                    if let value = FullscreenScrollbarMode(rawValue: newValue) {
                        callbacks.onFullscreenScrollbarChange(value)
                    }
                case "fullscreen-exit-output":
                    if let value = FullscreenExitOutput(rawValue: newValue) { callbacks.onFullscreenExitOutputChange(value) }
                case "fullscreen-copy-on-select":
                    callbacks.onFullscreenCopyOnSelectChange(newValue == "true")
                case "mouse-wheel-step":
                    if let value = Int(newValue) {
                        callbacks.onMouseWheelStepChange(value)
                    }
                case "mermaid-enabled":
                    callbacks.onMermaidEnabledChange(newValue == "true")
                case "mermaid-streaming":
                    callbacks.onMermaidRenderWhileStreamingChange(newValue == "true")
                case "latex-enabled":
                    callbacks.onLatexEnabledChange(newValue == "true")
                case "output-padding":
                    if let value = Int(newValue) {
                        callbacks.onOutputPadChange(value)
                    }
                default:
                    break
                }
            },
            onCancel: callbacks.onCancel,
            options: SettingsListOptions(enableSearch: true)
        )

        super.init()
        addChild(DynamicBorder())
        addChild(settingsList)
        addChild(DynamicBorder())
    }

    public func getSettingsList() -> SettingsList {
        settingsList
    }

    public override func handleInput(_ data: String) {
        // SettingsList treats Space as activation before it reaches its search input. Ignore the
        // separator while search is active. The fuzzy matcher still matches a multi-word label
        // when the query words are concatenated (for example, "outputpadding").
        if data == " " && !submenuState.isOpen { return }
        settingsList.handleInput(data)
    }
}

@MainActor
private final class ModelThinkingOverrideState {
    var levels: [String: ThinkingLevel]
    init(_ levels: [String: ThinkingLevel]) { self.levels = levels }
    var summary: String { levels.isEmpty ? "none" : "\(levels.count) configured" }
}

@MainActor
private func makeModelThinkingSubmenu(config: SettingsConfig, callbacks: SettingsCallbacks,
                                     state: ModelThinkingOverrideState,
                                     done: @escaping (String?) -> Void) -> SteppedSubmenu {
    let modelKey: (Model) -> String = { "\($0.provider)/\($0.id)" }
    let currentKey = config.currentModel.map(modelKey)
    let models = Dictionary(config.availableDefaultModels.map { (modelKey($0), $0) }, uniquingKeysWith: { _, new in new })
    let steps = [
        SteppedSubmenuStep(key: "model", title: { _ in "Per-Model Thinking Level" },
            description: { _ in "Select a model to configure" }, options: { _ in
                let sorted = config.availableDefaultModels.sorted { lhs, rhs in
                    let lhsKey = modelKey(lhs), rhsKey = modelKey(rhs)
                    if (lhsKey == currentKey) != (rhsKey == currentKey) { return lhsKey == currentKey }
                    if (lhsKey == config.defaultModel) != (rhsKey == config.defaultModel) { return lhsKey == config.defaultModel }
                    return lhs.provider.localizedCompare(rhs.provider) == .orderedAscending
                }
                if sorted.isEmpty {
                    return [SelectItem(value: "__none__", label: "No models available", description: "Log in to a provider or configure an API key first")]
                }
                return sorted.map { model in
                    SelectItem(value: modelKey(model), label: "\(model.id) [\(model.provider)]", description: state.levels[modelKey(model)]?.rawValue)
                }
            }, preselect: { _ in currentKey ?? (models[config.defaultModel] != nil ? config.defaultModel : nil) },
            searchable: true, layout: SelectListLayoutOptions(minPrimaryColumnWidth: 12, maxPrimaryColumnWidth: 46)),
        SteppedSubmenuStep(key: "level", title: { context in
            let key = context["model"] ?? ""
            return "Thinking Level for \(models[key].map { "\($0.id) [\($0.provider)]" } ?? key)"
        }, description: { _ in "Select default thinking level for this model" }, options: { context in
            guard let key = context["model"], let model = models[key] else { return [] }
            let levels: [ThinkingLevel] = model.reasoning
                ? getSupportedThinkingLevels(model).compactMap { ThinkingLevel(rawValue: $0.rawValue) } : [.off]
            var items = levels.map { level in
                SelectItem(value: level.rawValue, label: (level == state.levels[key] ? "✓ " : "  ") + level.rawValue, description: thinkingDescriptions[level])
            }
            if state.levels[key] != nil {
                items.append(SelectItem(value: "__clear__", label: "  (clear override)", description: "Revert to global default (\(config.thinkingLevel.rawValue))"))
            }
            return items
        }, preselect: { state.levels[$0["model"] ?? ""]?.rawValue })
    ]
    return SteppedSubmenu(steps: steps, onComplete: { context in
        guard let key = context["model"], let model = models[key], let value = context["level"] else { return }
        if value == "__clear__" {
            callbacks.onModelThinkingLevelRemove(model.provider, model.id)
            state.levels.removeValue(forKey: key)
        } else if let level = ThinkingLevel(rawValue: value) {
            callbacks.onModelThinkingLevelChange(model.provider, model.id, level)
            state.levels[key] = level
        }
    }, onCancel: { done(state.summary) }, loop: true)
}

@MainActor
private final class ThemeSettingsSubmenu: Container, MouseFocusOwner {
    private let original: String
    private let terminalTheme: TerminalColorScheme
    private let availableThemes: [String]
    private let callbacks: SettingsCallbacks
    private let done: (String?) -> Void
    private var single: String
    private var light: String
    private var dark: String
    private var active: (any Component)?

    init(currentTheme: String, terminalTheme: TerminalColorScheme, availableThemes: [String],
         callbacks: SettingsCallbacks, done: @escaping (String?) -> Void) {
        self.original = currentTheme; self.terminalTheme = terminalTheme
        self.availableThemes = availableThemes; self.callbacks = callbacks; self.done = done
        let pair = parseAutoThemeSetting(currentTheme)
        let fixed = availableThemes.contains(currentTheme) ? currentTheme : (availableThemes.contains("dark") ? "dark" : availableThemes.first ?? "dark")
        light = pair?.light ?? fixed
        dark = pair?.dark ?? fixed
        single = pair.map { terminalTheme == .light ? $0.light : $0.dark } ?? fixed
        super.init()
        if pair == nil { showSingle() } else { showAutomatic() }
    }
    private var automaticSetting: String { "\(light)/\(dark)" }
    private func items(current: String) -> [SelectItem] {
        availableThemes.map { SelectItem(value: $0, label: ($0 == current ? "✓ " : "  ") + $0) }
    }
    private func setContent(_ content: any Component, input: (any Component)? = nil) {
        clear(); addChild(content); active = input ?? content
    }
    private func cancel() { callbacks.onThemePreview?(original); done(nil) }
    private func showSingle() {
        let options = [SelectItem(value: "/", label: "  Automatic", description: "Use separate themes for light and dark terminal appearance")] + items(current: single)
        setContent(SelectSubmenu(title: "Theme", description: "Select a theme, or choose Automatic to follow terminal appearance.",
            options: options, currentValue: single, onSelect: { [weak self] value in
                guard let self else { return }
                if value == "/" { callbacks.onThemePreview?(automaticSetting); showAutomatic() }
                else { single = value; done(value) }
            }, onCancel: { [weak self] in self?.cancel() }, onSelectionChange: { [weak self] value in
                guard let self else { return }
                callbacks.onThemePreview?(value == "/" ? automaticSetting : value)
            }))
    }
    private func showAutomatic() {
        let content = Container()
        content.addChild(Text(theme.bold(theme.fg(.accent, "Automatic Theme")), paddingX: 0, paddingY: 0))
        content.addChild(Spacer(1))
        content.addChild(Text(theme.fg(.muted, "Choose themes for terminal light and dark appearance.\nLight/dark detection requires terminal support."), paddingX: 0, paddingY: 0))
        content.addChild(Spacer(1))
        let options = [
            SettingItem(id: "light-theme", label: "Light theme", currentValue: light, submenu: { [weak self] value, done in
                guard let self else { return Container() }
                return themeSelect(title: "Light Theme", current: value, done: done, onSelect: { [weak self] value in
                    guard let self else { return }; light = value; callbacks.onThemePreview?(automaticSetting); done(value)
                })
            }),
            SettingItem(id: "dark-theme", label: "Dark theme", currentValue: dark, submenu: { [weak self] value, done in
                guard let self else { return Container() }
                return themeSelect(title: "Dark Theme", current: value, done: done, onSelect: { [weak self] value in
                    guard let self else { return }; dark = value; callbacks.onThemePreview?(automaticSetting); done(value)
                })
            }),
            SettingItem(id: "apply", label: "Apply", currentValue: "save and go back", values: ["save and go back"]),
            SettingItem(id: "single-mode", label: "Change mode", currentValue: "switch to single theme", values: ["switch to single theme"])
        ]
        let list = SettingsList(items: options, maxVisible: 4, theme: getSettingsListTheme(), onChange: { [weak self] id, _ in
            guard let self else { return }
            if id == "apply" { done(automaticSetting) }
            else if id == "single-mode" { single = terminalTheme == .light ? light : dark; callbacks.onThemePreview?(single); showSingle() }
        }, onCancel: { [weak self] in self?.cancel() })
        content.addChild(list)
        setContent(content, input: list)
    }
    private func themeSelect(title: String, current: String, done: @escaping (String?) -> Void,
                             onSelect: @escaping (String) -> Void) -> SelectSubmenu {
        SelectSubmenu(title: title, description: "Select the theme to use for terminal appearance", options: items(current: current),
                      currentValue: current, onSelect: onSelect, onCancel: { [weak self] in
                          guard let self else { return }; callbacks.onThemePreview?(automaticSetting); done(nil)
                      }, onSelectionChange: callbacks.onThemePreview)
    }
    override func handleInput(_ data: String) { active?.handleInput(data) }
}
