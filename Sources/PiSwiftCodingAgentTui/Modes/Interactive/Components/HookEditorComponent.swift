import Foundation
import MiniTui
import PiSwiftCodingAgent

@MainActor
public final class HookEditorComponent: Container, SystemCursorAware {
    private let editor: Editor
    private let onSubmitCallback: (String) -> Void
    private let onCancelCallback: () -> Void
    private let tui: TUI
    private let externalEditorCommand: String
    private let editorFailure = Text("")
    public var usesSystemCursor: Bool {
        get { editor.usesSystemCursor }
        set { editor.usesSystemCursor = newValue }
    }

    public init(
        tui: TUI,
        title: String,
        prefill: String? = nil,
        description: String? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        externalEditorCommand: String? = nil
    ) {
        self.tui = tui
        self.onSubmitCallback = onSubmit
        self.onCancelCallback = onCancel
        self.externalEditorCommand = externalEditorCommand
            ?? ProcessInfo.processInfo.environment["VISUAL"]
            ?? ProcessInfo.processInfo.environment["EDITOR"]
            ?? "nano"
        self.editor = Editor(theme: getEditorTheme())

        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, title), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        if let description, !description.isEmpty {
            addChild(Text(theme.fg(.dim, description), paddingX: 1, paddingY: 0))
            addChild(Spacer(1))
        }

        if let prefill {
            editor.setText(prefill)
        }
        addChild(editor)
        addChild(editorFailure)

        addChild(Spacer(1))
        let hint = "ctrl+enter submit  esc cancel  ctrl+g external editor"
        addChild(Text(theme.fg(.dim, hint), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())
    }

    public override func handleInput(_ keyData: String) {
        if keyData == "\u{001B}[13;5u" || keyData == "\u{001B}[27;5;13~" {
            onSubmitCallback(editor.getText())
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
            return
        }
        if isCtrlG(keyData) {
            openExternalEditor()
            return
        }
        editor.handleInput(keyData)
    }

    private func openExternalEditor() {
        tui.stop()
        let result = editInExternalEditor(command: externalEditorCommand, content: editor.getText())
        tui.start()
        switch result {
        case .complete(let content):
            editor.setText(content)
            editorFailure.setText("")
        case .failed(let message):
            editorFailure.setText(theme.fg(.warning, message))
        }
        tui.requestRender()
    }
}
