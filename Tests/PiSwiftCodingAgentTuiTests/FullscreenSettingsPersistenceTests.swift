import Foundation
import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI
@testable import PiSwiftCodingAgentTui

private func withFullscreenSettingsTempDirectories(
    _ body: (URL, URL, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-fullscreen-settings-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project")
    let agent = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root, project, agent)
}

@Test func fullscreenSettingsPersistReloadAndRejectInvalidStoredValues() throws {
    try withFullscreenSettingsTempDirectories { _, project, agent in
        let manager = SettingsManager.create(project.path, agent.path, projectTrusted: false)
        manager.setTuiMode("fullscreen")
        manager.setFullscreenScrollbar("hidden")
        manager.setMouseWheelStep(7)
        manager.setMermaidEnabled(false)
        manager.setMermaidRenderWhileStreaming(false)
        manager.setLatexEnabled(true)
        manager.setOutputPad(0)

        let reloaded = SettingsManager.create(project.path, agent.path, projectTrusted: false)
        #expect(reloaded.getTuiMode() == "fullscreen")
        #expect(reloaded.getFullscreenScrollbar() == "hidden")
        #expect(reloaded.getMouseWheelStep() == 7)
        #expect(reloaded.getMermaidEnabled() == false)
        #expect(reloaded.getMermaidRenderWhileStreaming() == false)
        #expect(reloaded.getLatexEnabled() == true)
        #expect(reloaded.getOutputPad() == 0)

        let configuration = InteractiveTuiConfiguration(settingsManager: reloaded)
        #expect(configuration == InteractiveTuiConfiguration(
            mode: .fullscreen,
            scrollbar: .hidden,
            mouseWheelStep: 7,
            mermaidEnabled: false,
            mermaidRenderWhileStreaming: false,
            latexEnabled: true,
            outputPad: 0
        ))

        let settingsPath = agent.appendingPathComponent("settings.json")
        let invalid: [String: Any] = [
            "tuiMode": "invalid",
            "fullscreenScrollbar": "invalid",
            "mouseWheelStep": 0,
            "outputPad": 2,
            "markdown": [
                "mermaidEnabled": "invalid",
                "mermaidRenderWhileStreaming": "invalid",
                "latexEnabled": "invalid",
            ],
        ]
        let invalidData = try JSONSerialization.data(withJSONObject: invalid, options: [.prettyPrinted])
        try invalidData.write(to: settingsPath)

        let defaults = SettingsManager.create(project.path, agent.path, projectTrusted: false)
        // Upstream v1.0.0 settings-manager.test.ts: an invalid stored mode falls back to fullscreen.
        #expect(defaults.getTuiMode() == "fullscreen")
        #expect(defaults.getFullscreenScrollbar() == "auto")
        #expect(defaults.getMouseWheelStep() == 1)
        #expect(defaults.getMermaidEnabled() == true)
        #expect(defaults.getMermaidRenderWhileStreaming() == true)
        #expect(defaults.getLatexEnabled() == false)
        #expect(defaults.getOutputPad() == 1)
    }
}

@Test func tuiModeFlagOverridesPersistedModeWithoutChangingIt() throws {
    try withFullscreenSettingsTempDirectories { _, project, agent in
        let manager = SettingsManager.create(project.path, agent.path, projectTrusted: false)
        manager.setTuiMode("fullscreen")

        let defaults = try CLIOptions.parse([])
        #expect(defaults.resolvedTuiMode(settingsManager: manager) == .fullscreen)

        let override = try CLIOptions.parse(["--tui-mode", "regular"])
        #expect(override.resolvedTuiMode(settingsManager: manager) == .regular)
        #expect(SettingsManager.create(project.path, agent.path, projectTrusted: false).getTuiMode() == "fullscreen")
    }
}

@Test func projectMarkdownOverridePreservesGlobalSiblingValues() throws {
    try withFullscreenSettingsTempDirectories { _, project, agent in
        let globalSettings: [String: Any] = [
            "markdown": [
                "mermaidEnabled": false,
                "mermaidRenderWhileStreaming": false,
                "latexEnabled": true,
            ],
        ]
        let projectSettings: [String: Any] = [
            "markdown": ["mermaidEnabled": true],
        ]
        try JSONSerialization.data(withJSONObject: globalSettings)
            .write(to: agent.appendingPathComponent("settings.json"))
        let projectSettingsDirectory = project.appendingPathComponent(".pi")
        try FileManager.default.createDirectory(at: projectSettingsDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: projectSettings)
            .write(to: projectSettingsDirectory.appendingPathComponent("settings.json"))

        let manager = SettingsManager.create(project.path, agent.path, projectTrusted: true)
        #expect(manager.getMermaidEnabled() == true)
        #expect(manager.getMermaidRenderWhileStreaming() == false)
        #expect(manager.getLatexEnabled() == true)
    }
}

private final class ThemeProbeTerminal: Terminal {
    // pi-mono v0.99.0 replaced the `ESC[?996n` scheme query and the lone OSC 11 query with one
    // OSC 10/11/4 + DA1 query (`queryTerminalColors`); these probes answer that query.
    enum Reply {
        case lightBackground
        case neither
    }

    let columns = 80
    let rows = 24
    let kittyProtocolActive = false
    private let reply: Reply
    private var onInput: ((String) -> Void)?
    private var replied = false
    private(set) var writes: [String] = []

    init(reply: Reply) {
        self.reply = reply
    }

    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        self.onInput = onInput
    }

    func stop() { onInput = nil }
    func drainInput(maxMs: Int, idleMs: Int) {}

    func write(_ data: String) {
        writes.append(data)
        guard !replied, data.contains("\u{001B}]11;?\u{0007}") else { return }
        switch reply {
        case .lightBackground:
            replied = true
            onInput?("\u{001B}]11;rgb:ffff/ffff/ffff\u{0007}\u{001B}[?1;2c")
        case .neither:
            break
        }
    }

    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor
private func detectedTheme(
    reply: ThemeProbeTerminal.Reply,
    reportedScheme: TerminalColorScheme? = nil,
    environment: [String: String] = [:]
) async -> (TerminalColorScheme, [String]) {
    let terminal = ThemeProbeTerminal(reply: reply)
    let tui = TUI(terminal: terminal)
    tui.start()
    let result = await detectTerminalTheme(
        ui: tui, timeoutMs: 10, reportedScheme: reportedScheme, environment: environment
    )
    tui.stop()
    return (result, terminal.writes)
}

@MainActor
@Test func themeDetectionPrefersReportedBackground() async {
    let (result, writes) = await detectedTheme(reply: .lightBackground, reportedScheme: .dark)
    #expect(result == .light)
    #expect(writes.contains { $0.contains("\u{001B}]10;?\u{0007}") && $0.contains("\u{001B}]11;?\u{0007}") })
    #expect(!writes.contains { $0.contains("\u{001B}[?996n") })
}

@MainActor
@Test func themeDetectionUsesReportedSchemeWithoutBackground() async {
    let (result, _) = await detectedTheme(reply: .neither, reportedScheme: .light, environment: ["COLORFGBG": "15;0"])
    #expect(result == .light)
}

@MainActor
@Test func themeDetectionTimesOutToExistingEnvironmentFallback() async {
    let (result, writes) = await detectedTheme(reply: .neither, environment: ["COLORFGBG": "15;0"])
    #expect(result == .dark)
    #expect(writes.contains { $0.contains("\u{001B}]11;?\u{0007}") })
}

@MainActor
private final class OutputPaddingTestUI: RenderRequesting {
    func requestRender() {}
}

@MainActor
@Test func interactiveErrorsHonorConfiguredOutputPadding() throws {
    initTheme("dark")
    let unpadded = InteractiveMode(
        chatContainer: Container(),
        ui: OutputPaddingTestUI(),
        tuiConfiguration: InteractiveTuiConfiguration(outputPad: 0)
    )
    unpadded.showError("failure")
    let unpaddedLine = try #require(unpadded.chatContainer.children.last?.render(width: 80).first)
    #expect(unpaddedLine.hasPrefix("\u{001B}"))

    let padded = InteractiveMode(
        chatContainer: Container(),
        ui: OutputPaddingTestUI(),
        tuiConfiguration: InteractiveTuiConfiguration(outputPad: 1)
    )
    padded.showError("failure")
    let paddedLine = try #require(padded.chatContainer.children.last?.render(width: 80).first)
    #expect(paddedLine.hasPrefix(" "))
}

@Suite(.serialized)
struct FullscreenScrollbarThemeTests {
    @MainActor
    @Test func scrollbarUsesForegroundTokensAndLegacyThemeFallsBackToText() throws {
        let name = "pi-scrollbar-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            setRegisteredThemes([])
            initTheme("dark")
            try? FileManager.default.removeItem(at: root)
        }

        var colors = getResolvedThemeColors("dark")
        colors.removeValue(forKey: ThemeColor.scrollbarThumb.rawValue)
        colors[ThemeColor.scrollbarThumb.rawValue] = "#123456"
        let explicitTheme: [String: Any] = ["name": name, "colors": colors]
        let themePath = root.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: explicitTheme, options: [.prettyPrinted]).write(to: themePath)
        setRegisteredThemes([HookThemeInfo(name: name, path: themePath.path)])
        #expect(setTheme(name).success)

        let composition = InteractiveComposition(
            transcriptChildren: [Text("chat", paddingX: 0, paddingY: 0)],
            pendingMessages: Text("", paddingX: 0, paddingY: 0),
            status: Text("", paddingX: 0, paddingY: 0),
            widgets: Text("", paddingX: 0, paddingY: 0),
            editorSpacer: Spacer(1),
            editor: Text("editor", paddingX: 0, paddingY: 0),
            footer: Text("footer", paddingX: 0, paddingY: 0),
            scrollbar: .always,
            scrollbarStyle: fullscreenScrollbarStyle
        )
        #expect(composition.transcriptScrollView.scrollbarThumbStyle("x") == theme.fg(.scrollbarThumb, "x"))

        colors.removeValue(forKey: ThemeColor.scrollbarThumb.rawValue)
        let legacyName = "\(name)-legacy"
        let legacyTheme: [String: Any] = ["name": legacyName, "colors": colors]
        let legacyPath = root.appendingPathComponent("\(legacyName).json")
        try JSONSerialization.data(withJSONObject: legacyTheme, options: [.prettyPrinted]).write(to: legacyPath)
        setRegisteredThemes([HookThemeInfo(name: legacyName, path: legacyPath.path)])
        let resolved = getResolvedThemeColors(legacyName)
        #expect(resolved[ThemeColor.scrollbarThumb.rawValue] == resolved[ThemeColor.text.rawValue])
    }
}
