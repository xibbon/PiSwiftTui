import Foundation
import MiniTui
import PiSwiftCodingAgent

public protocol WorkingStatusEditor: EditorComponent {
    var embedWorkingStatus: Bool { get }
    func setWorkingStatusIndicator(_ indicator: WorkingStatusIndicator?)
}

public final class CustomEditor: Component, SystemCursorAware, EditorComponent, WorkingStatusEditor {
    private let editor: WorkingBorderEditor
    private let keybindings: KeybindingsManager
    private var explicitHistory: [String] = []
    private var explicitHistoryIndex = -1
    private var explicitHistoryDraft = ""
    public var actionHandlers: [AppAction: () -> Void] = [:]

    public var usesSystemCursor: Bool {
        get { editor.usesSystemCursor }
        set { editor.usesSystemCursor = newValue }
    }

    public var onEscape: (() -> Void)?
    public var onCtrlD: (() -> Void)?
    public var onPasteImage: (() -> Void)?
    public var onHookShortcut: ((String) -> Bool)?

    public var onSubmit: ((String) -> Void)? {
        get { editor.onSubmit }
        set { editor.onSubmit = newValue }
    }

    public var onChange: ((String) -> Void)? {
        get { editor.onChange }
        set { editor.onChange = newValue }
    }

    public var disableSubmit: Bool {
        get { editor.disableSubmit }
        set { editor.disableSubmit = newValue }
    }

    public var borderColor: @Sendable (String) -> String {
        get { editor.borderColor }
        set { editor.borderColor = newValue }
    }

    public init(ui: TUI? = nil, theme: EditorTheme, keybindings: KeybindingsManager, options: EditorOptions = EditorOptions(), embedWorkingStatus: Bool = false) {
        self.editor = WorkingBorderEditor(ui: ui, theme: theme, options: options)
        self.editor.embedWorkingStatus = embedWorkingStatus
        self.keybindings = keybindings
    }

    public var embedWorkingStatus: Bool { editor.embedWorkingStatus }

    public func setWorkingStatusIndicator(_ indicator: WorkingStatusIndicator?) {
        editor.workingStatusIndicator = indicator
    }

    public func handleMouse(_ event: TuiMouseEvent) -> TuiMouseEventResult? {
        editor.handleMouse(event)
    }

    public func onAction(_ action: AppAction, handler: @escaping () -> Void) {
        actionHandlers[action] = handler
    }

    public func setText(_ text: String) {
        editor.setText(text)
        explicitHistoryIndex = -1
    }

    public func getText() -> String {
        editor.getText()
    }

    public func getExpandedText() -> String {
        editor.getExpandedText()
    }

    public func getPasteCursor() -> (line: Int, col: Int)? { editor.getCursor() }

    public func insertTextAtCursor(_ text: String) {
        editor.insertTextAtCursor(text)
    }

    public func addToHistory(_ text: String) {
        editor.addToHistory(text)
        if explicitHistory.last != text {
            explicitHistory.append(text)
            if explicitHistory.count > 100 {
                explicitHistory.removeFirst(explicitHistory.count - 100)
            }
        }
        explicitHistoryIndex = -1
    }

    public func setAutocompleteProvider(_ provider: AutocompleteProvider) {
        editor.setAutocompleteProvider(provider)
    }

    public func setPaddingX(_ padding: Int) {
        editor.setPaddingX(padding)
    }

    public func getPaddingX() -> Int {
        editor.getPaddingX()
    }

    public func setAutocompleteMaxVisible(_ maxVisible: Int) {
        editor.setAutocompleteMaxVisible(maxVisible)
    }

    public func isShowingAutocomplete() -> Bool {
        editor.isShowingAutocomplete()
    }

    public func invalidate() {
        editor.invalidate()
    }

    public func render(width: Int) -> [String] {
        editor.render(width: width)
    }

    public func handleInput(_ data: String) {
        if onHookShortcut?(data) == true {
            return
        }

        if keybindings.matches(data, .pasteImage) {
            onPasteImage?()
            return
        }

        if keybindings.matches(data, .interrupt) {
            if !editor.isShowingAutocomplete() {
                let handler = onEscape ?? actionHandlers[.interrupt]
                handler?()
                return
            }
            editor.handleInput(data)
            return
        }

        if keybindings.matches(data, .exit) {
            if editor.getText().isEmpty {
                let handler = onCtrlD ?? actionHandlers[.exit]
                handler?()
                return
            }
        }

        // Explicit prompt-history bindings take precedence over app actions while the editor has
        // focus. Ctrl+P therefore still cycles models elsewhere, but it navigates prompt history
        // here when the user binds it to tui.editor.historyPrevious.
        let tuiKeybindings = getKeybindings()
        if tuiKeybindings.matches(data, TUIKeybinding.editorHistoryPrevious) {
            navigateExplicitHistory(previous: true)
            return
        }
        if tuiKeybindings.matches(data, TUIKeybinding.editorHistoryNext) {
            navigateExplicitHistory(previous: false)
            return
        }

        for (action, handler) in actionHandlers where action != .interrupt && action != .exit {
            if keybindings.matches(data, action) {
                handler()
                return
            }
        }

        editor.handleInput(data)
    }

    private func navigateExplicitHistory(previous: Bool) {
        guard !explicitHistory.isEmpty else { return }
        if previous {
            if explicitHistoryIndex == -1 {
                explicitHistoryDraft = editor.getText()
                explicitHistoryIndex = explicitHistory.count - 1
            } else if explicitHistoryIndex > 0 {
                explicitHistoryIndex -= 1
            }
            editor.setText(explicitHistory[explicitHistoryIndex])
            return
        }

        guard explicitHistoryIndex >= 0 else { return }
        if explicitHistoryIndex < explicitHistory.count - 1 {
            explicitHistoryIndex += 1
            editor.setText(explicitHistory[explicitHistoryIndex])
        } else {
            explicitHistoryIndex = -1
            editor.setText(explicitHistoryDraft)
        }
    }
}

private final class WorkingBorderEditor: Editor {
    var embedWorkingStatus = false
    var workingStatusIndicator: WorkingStatusIndicator?

    override func renderTopBorder(width: Int, hiddenLineCount: Int) -> String {
        guard embedWorkingStatus, let indicator = workingStatusIndicator, width > 0 else {
            return super.renderTopBorder(width: width, hiddenLineCount: hiddenLineCount)
        }
        var status = indicator.renderInBorder(width: max(1, width - 5))
        var statusWidth = visibleWidth(status)
        guard statusWidth > 0 else { return super.renderTopBorder(width: width, hiddenLineCount: hiddenLineCount) }
        let label = hiddenLineCount > 0 ? " ↑ \(hiddenLineCount) more " : ""
        let labelWidth = visibleWidth(label)
        let start = (width - labelWidth) / 2
        func fits() -> Bool { !label.isEmpty && labelWidth + 2 <= width && start - (4 + statusWidth) >= 1 }
        if !label.isEmpty && !fits() {
            status = indicator.renderSpinnerInBorder(width: width)
            statusWidth = visibleWidth(status)
        }
        if fits() {
            return borderColor("── ") + status + borderColor(" " + String(repeating: "─", count: start - 4 - statusWidth) + label + String(repeating: "─", count: width - start - labelWidth))
        }
        if width >= statusWidth + 5 {
            return borderColor("── ") + status + borderColor(" " + String(repeating: "─", count: width - statusWidth - 4))
        }
        status = indicator.renderSpinnerInBorder(width: width)
        statusWidth = visibleWidth(status)
        let prefix = min(3, max(0, width - statusWidth))
        return borderColor(String(repeating: "─", count: prefix)) + status + borderColor(String(repeating: "─", count: max(0, width - prefix - statusWidth)))
    }
}
