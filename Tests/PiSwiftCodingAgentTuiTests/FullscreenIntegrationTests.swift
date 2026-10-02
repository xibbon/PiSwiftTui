import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI
@testable import PiSwiftCodingAgentTui

private final class FullscreenTestTerminal: Terminal {
    var writes: [String] = []
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var stopped = false
    var drainCount = 0
    private var onInput: ((String) -> Void)?

    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        self.onInput = onInput
        stopped = false
    }

    func stop() {
        stopped = true
        onInput = nil
    }

    func drainInput(maxMs: Int, idleMs: Int) { drainCount += 1 }
    func write(_ data: String) { writes.append(data) }
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@Test func tuiModeOptionHasNoOverrideAndParsesFullscreen() throws {
    let defaults = try CLIOptions.parse([])
    // Upstream v1.0.0: no CLI flag uses the fullscreen setting default.
    #expect(defaults.parsedTuiModeOverride == nil)

    let fullscreen = try CLIOptions.parse(["--tui-mode", "fullscreen"])
    #expect(fullscreen.parsedTuiModeOverride == .fullscreen)
}

@Test func invalidTuiModeHasClearDiagnostic() {
    #expect(throws: (any Error).self) {
        _ = try CLIOptions.parse(["--tui-mode", "windowed"])
    }

    do {
        _ = try CLIOptions.parse(["--tui-mode", "windowed"])
        Issue.record("Expected invalid TUI mode to fail")
    } catch {
        #expect(String(describing: error).contains("--tui-mode requires regular or fullscreen"))
    }
}

@MainActor
@Test func runtimeRendererSwitchEntersAndLeavesAlternateScreen() async {
    let terminal = FullscreenTestTerminal()
    let tui = TUI(terminal: terminal)
    let transcript = Container()
    transcript.addChild(Text("message", paddingX: 0, paddingY: 0))
    let scrollView = ScrollView(transcript, options: ScrollViewOptions(follow: .end, primary: true))
    let root = VStack([scrollView, Text("dock", paddingX: 0, paddingY: 0)])
    let alternate = tui.enableAltScreen()
    alternate.setLayoutRoot(root)
    tui.addChild(transcript)
    tui.start()

    #expect(tui.mode == .mainScreen)
    #expect(tui.switchRenderer(to: .altScreen))
    #expect(tui.mode == .altScreen)
    #expect(terminal.writes.joined().contains("\u{001B}[?1049h"))

    #expect(tui.switchRenderer(to: .mainScreen))
    #expect(tui.mode == .mainScreen)
    #expect(terminal.writes.joined().contains("\u{001B}[?1049l"))

    tui.stop()
    #expect(terminal.stopped)
}

@MainActor
@Test func fullscreenCompositionScrollsTranscriptAndKeepsDockSticky() {
    let header = Text("header", paddingX: 0, paddingY: 0)
    let chat = Container()
    for index in 0..<20 {
        chat.addChild(Text("message \(index)", paddingX: 0, paddingY: 0))
    }
    let pending = Text("pending", paddingX: 0, paddingY: 0)
    let status = Text("status", paddingX: 0, paddingY: 0)
    let widgets = Text("widgets", paddingX: 0, paddingY: 0)
    let spacer = Spacer(1)
    let editor = Text("editor\nline 2\nline 3", paddingX: 0, paddingY: 0)
    let footer = Text("footer", paddingX: 0, paddingY: 0)
    let composition = InteractiveComposition(
        transcriptChildren: [header, chat],
        pendingMessages: pending,
        status: status,
        widgets: widgets,
        editorSpacer: spacer,
        editor: editor,
        footer: footer,
        scrollbar: .auto,
        scrollbarStyle: { $0 }
    )

    #expect(composition.regularChildren.count == 8)
    #expect(composition.regularChildren[0] === header)
    #expect(composition.regularChildren[1] === chat)
    #expect(composition.regularChildren[2] === pending)
    #expect(composition.regularChildren[7] === footer)

    let frame = renderLayoutFrame(root: composition.fullscreenRoot, width: 60, height: 12, requestRender: {})
    #expect(frame.primaryScrollView === composition.transcriptScrollView)
    #expect(frame.root.children.count == 2)
    let transcriptBox = frame.root.children[0]
    let dockBox = frame.root.children[1]
    #expect(transcriptBox.rect.y == 0)
    #expect(dockBox.rect.y == transcriptBox.rect.height)
    #expect(dockBox.rect.y + dockBox.rect.height == 12)
    #expect(frame.lines.last?.contains("footer") == true)
}

@Test func mermaidTransformRendersSupportedDiagramAndPreservesUnsupportedDiagram() {
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(theme: nil))
    let supported = "Before\n\n```mermaid\nflowchart LR\n  A[Start] --> B[Done]\n```\nAfter"
    let rendered = transform(supported, 100)
    #expect(rendered.contains("┌───────┐"))
    #expect(rendered.contains("│ Start ├───▶│ Done │"))
    #expect(!rendered.contains("```mermaid"))
    #expect(rendered.contains("After"))

    let unsupported = "```mermaid\npie\n  title Pets\n  \"Dogs\" : 4\n```"
    #expect(transform(unsupported, 100) == unsupported)
}

@MainActor
@Test func explicitPromptHistoryBindingsOverrideModelCyclingOnlyInEditor() {
    defer { setKeybindings(TUIKeybindingsManager()) }
    let appKeybindings = KeybindingsManager.inMemory(config: [
        AppAction.cycleModelForward.rawValue: [MiniTui.Key.ctrl("p")],
    ])

    setKeybindings(TUIKeybindingsManager())
    let modelEditor = CustomEditor(theme: getEditorTheme(), keybindings: appKeybindings)
    var modelCycles = 0
    modelEditor.onAction(.cycleModelForward) { modelCycles += 1 }
    modelEditor.handleInput("\u{10}")
    #expect(modelCycles == 1)

    setKeybindings(TUIKeybindingsManager(userBindings: [
        TUIKeybinding.editorHistoryPrevious: [MiniTui.Key.ctrl("p")],
        TUIKeybinding.editorHistoryNext: [MiniTui.Key.ctrl("n")],
    ]))
    let historyEditor = CustomEditor(theme: getEditorTheme(), keybindings: appKeybindings)
    historyEditor.onAction(.cycleModelForward) { modelCycles += 1 }
    historyEditor.addToHistory("previous prompt")
    historyEditor.setText("draft")

    historyEditor.handleInput("\u{10}")
    #expect(historyEditor.getText() == "previous prompt")
    #expect(modelCycles == 1)

    historyEditor.handleInput("\u{0E}")
    #expect(historyEditor.getText() == "draft")
}
