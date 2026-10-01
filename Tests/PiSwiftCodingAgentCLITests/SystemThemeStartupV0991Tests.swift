import Foundation
import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI
@testable import PiSwiftCodingAgentTui

@MainActor
private final class StartupColorProbe: TerminalThemeProbing {
    var answer: CheckedContinuation<MiniTui.TerminalColors, Never>?
    var lateReply: (@MainActor (MiniTui.TerminalColors) -> Void)?
    func queryTerminalColors(timeoutMs: Int, onLateReply: (@MainActor (MiniTui.TerminalColors) -> Void)?) async -> MiniTui.TerminalColors {
        #expect(timeoutMs == 100)
        lateReply = onLateReply
        return await withCheckedContinuation { answer = $0 }
    }
}

@MainActor
private final class StartupThemePreview {
    var name = "system"
}

@MainActor @Suite(.serialized)
struct SystemThemeStartupV0991Tests {
    private func reset() {
        setCapabilityOverrides(MiniTui.TerminalCapabilityOverrides())
        PiSwiftCodingAgent.setTerminalColors(PiSwiftCodingAgent.TerminalColors())
        PiSwiftCodingAgent.setTerminalColorScheme(nil)
        PiSwiftCodingAgent.setTerminalColorMode(.truecolor)
        initTheme("dark")
        stopThemeWatcher()
    }

    @Test func startupSetsEffectiveModeBeforeInitialGrayscaleSystemLoad() {
        defer { reset() }
        var settings = Settings()
        settings.terminal = TerminalSettings(trueColor: .enabled(false))
        let manager = SettingsManager.inMemory(settings)
        initializeStartupTheme(manager)
        #expect(theme.name == "system")
        #expect(theme.getColorMode() == "256color")
        #expect(theme.getFgAnsi(.error) == "\u{001B}[39m")
        #expect(manager.getTheme() == nil)
    }

    @Test func capabilityModeAppliesToAllThemesAndRuntimeChanges() {
        defer { reset() }
        var settings = Settings(); settings.theme = "light"
        settings.terminal = TerminalSettings(trueColor: .enabled(false))
        let manager = SettingsManager.inMemory(settings)
        initializeStartupTheme(manager)
        #expect(theme.getColorMode() == "256color")
        var overrides = Settings(); overrides.terminal = TerminalSettings(trueColor: .enabled(true))
        manager.applyOverrides(overrides)
        applyInteractiveTerminalCapabilities(manager)
        _ = setTheme("light")
        #expect(theme.getColorMode() == "truecolor")
        #expect(theme.getFgAnsi(.accent).contains("38;2;"))
        overrides.terminal = TerminalSettings(trueColor: .enabled(false))
        manager.applyOverrides(overrides)
        applyStartupTerminalSettings(manager)
        _ = setTheme("dark")
        #expect(theme.getColorMode() == "256color")
    }

    @Test func startupQueryDoesNotBlockAndRebuildsOnFirstAndLateReplies() async throws {
        defer { reset() }
        let manager = SettingsManager.inMemory()
        initializeStartupTheme(manager)
        let ui = StartupColorProbe()
        let component = FirstTimeSetupComponent(onThemePreview: { _ in }, onSubmit: { _ in }, onCancel: {})
        let before = component.render(width: 100)
        var renders = 0
        let query = queryStartupTerminalColors(ui, onColors: { _ = setTheme("system") }, onRender: {
            component.invalidate(); renders += 1
        })
        #expect(renders == 0)
        #expect(theme.getFgAnsi(.error) == "\u{001B}[39m")
        await Task.yield()
        let answer = try #require(ui.answer)
        answer.resume(returning: MiniTui.TerminalColors())
        await query.value
        #expect(theme.getFgAnsi(.error) == "\u{001B}[38;5;1m")
        #expect(renders == 1)
        let late = try #require(ui.lateReply)
        late(MiniTui.TerminalColors(foreground: RgbColor(r: 248, g: 248, b: 242), background: RgbColor(r: 40, g: 42, b: 54)))
        #expect(renders == 2)
        #expect(component.render(width: 100) != before)
        #expect(manager.getTheme() == nil)
    }

    @Test func firstSetupQueryKeepsTheCurrentPreview() async throws {
        defer { reset() }
        initializeStartupTheme(SettingsManager.inMemory())
        let ui = StartupColorProbe()
        let preview = StartupThemePreview()
        let query = queryStartupTerminalColors(ui, onColors: { _ = setTheme(preview.name) }, onRender: {})
        preview.name = "light"; _ = setTheme(preview.name)
        await Task.yield()
        let answer = try #require(ui.answer)
        answer.resume(returning: MiniTui.TerminalColors(background: RgbColor(r: 0, g: 0, b: 0)))
        await query.value
        #expect(theme.name == "light")
        ui.lateReply?(MiniTui.TerminalColors(background: RgbColor(r: 250, g: 250, b: 250)))
        #expect(theme.name == "light")
    }

    @Test func startupTrustPromptRecolorsAfterTerminalReply() {
        defer { reset() }
        initializeStartupTheme(SettingsManager.inMemory())
        let prompt = ProjectTrustSelectorComponent(cwd: "/tmp/theme-project", options: getProjectTrustOptions("/tmp/theme-project"),
                                                  onSelect: { _ in }, onCancel: {})
        let before = prompt.render(width: 120)
        PiSwiftCodingAgent.setTerminalColors(MiniTui.TerminalColors(
            foreground: RgbColor(r: 248, g: 248, b: 242), background: RgbColor(r: 40, g: 42, b: 54)
        ).codingAgentColors)
        _ = setTheme("system")
        prompt.invalidate()
        let after = prompt.render(width: 120)
        #expect(after != before)
        #expect(after.joined().contains("Project trust required"))
        #expect(after.joined().contains(theme.getFgAnsi(.accent)))
    }

    @Test func startupThemesSkipDisabledBrokenAndDuplicateResources() throws {
        defer { reset() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-startup-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let colors = getResolvedThemeColors("dark")
        let first = root.appendingPathComponent("first.json")
        let duplicate = root.appendingPathComponent("duplicate.json")
        let disabled = root.appendingPathComponent("disabled.json")
        let broken = root.appendingPathComponent("broken.json")
        let data = try JSONSerialization.data(withJSONObject: ["name": "startup-theme", "colors": colors])
        try data.write(to: first); try data.write(to: duplicate)
        try JSONSerialization.data(withJSONObject: ["name": "disabled-theme", "colors": colors]).write(to: disabled)
        try Data("not JSON".utf8).write(to: broken)
        func resource(_ path: URL, enabled: Bool = true) -> ResolvedResource {
            ResolvedResource(path: path.path, enabled: enabled,
                             metadata: PathMetadata(source: "local", scope: "user", origin: "top-level"))
        }
        let themes = loadStartupThemes([resource(first), resource(duplicate), resource(disabled, enabled: false), resource(broken)])
        #expect(themes.count == 1)
        #expect(themes.first?.name == "startup-theme")
        #expect(themes.first?.path == first.path)
    }
}
