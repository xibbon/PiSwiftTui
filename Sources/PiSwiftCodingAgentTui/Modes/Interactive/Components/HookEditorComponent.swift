import Foundation
import MiniTui
import PiSwiftCodingAgent

@MainActor
public final class HookEditorComponent: Container, SystemCursorAware {
    private let editor: Editor
    private let onSubmitCallback: (String) -> Void
    private let onCancelCallback: () -> Void
    private let tui: TUI
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
        onCancel: @escaping () -> Void
    ) {
        self.tui = tui
        self.onSubmitCallback = onSubmit
        self.onCancelCallback = onCancel
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

        addChild(Spacer(1))
        let hasExternal = (ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"]) != nil
        let hint = hasExternal
            ? "ctrl+enter submit  esc cancel  ctrl+g external editor"
            : "ctrl+enter submit  esc cancel"
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
        let env = ProcessInfo.processInfo.environment
        let editorCmd = env["VISUAL"] ?? env["EDITOR"]
        guard let editorCmd else { return }

        let currentText = editor.getText()
        let tmpFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("pi-hook-editor-\(Int(Date().timeIntervalSince1970)).md")

        do {
            try currentText.write(toFile: tmpFile, atomically: true, encoding: .utf8)
            tui.stop()

            let components = editorCmd.split(separator: " ").map(String.init)
            guard let editorExec = components.first else { return }
            let args = Array(components.dropFirst()) + [tmpFile]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: editorExec)
            process.arguments = args
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let newContent = try String(contentsOfFile: tmpFile, encoding: .utf8)
                    .replacingOccurrences(of: "\n$", with: "", options: .regularExpression)
                editor.setText(newContent)
            }
        } catch {
            // Ignore errors; fall back to current editor state.
        }

        try? FileManager.default.removeItem(atPath: tmpFile)
        tui.start()
        tui.requestRender()
    }
}
