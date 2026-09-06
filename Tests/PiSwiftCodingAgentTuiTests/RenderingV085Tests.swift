import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class RenderingTerminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    private var onInput: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { self.onInput = onInput }
    func emit(_ text: String) { onInput?(text) }
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor @Suite(.serialized) struct RenderingV085Tests {
    @Test func workingIndicatorUsesBorderAndFitsNarrowWidths() throws {
        let ui = TUI(terminal: RenderingTerminal())
        let indicator = WorkingStatusIndicator(ui: ui, indicator: LoaderIndicatorOptions(frames: ["*"]))
        defer { indicator.stop() }
        let editor = CustomEditor(ui: ui, theme: getEditorTheme(), keybindings: KeybindingsManager.create(), embedWorkingStatus: true)
        editor.setWorkingStatusIndicator(indicator)
        #expect(renderingStripAnsi(editor.render(width: 50)[0]).contains("── * Working"))
        for width in 1...15 {
            #expect(visibleWidth(editor.render(width: width)[0]) <= width)
        }
        editor.setText((1...20).map { "line \($0)" }.joined(separator: "\n"))
        let border = renderingStripAnsi(editor.render(width: 60)[0])
        #expect(border.contains(" ↑ "))
        #expect(border.contains(" more "))
        editor.setWorkingStatusIndicator(nil)
        #expect(!renderingStripAnsi(editor.render(width: 60)[0]).contains("Working"))
    }

    @Test func embeddedDefaultSpinnerAndMessageUseBorderColor() {
        let ui = TUI(terminal: RenderingTerminal())
        let editor = CustomEditor(ui: ui, theme: getEditorTheme(), keybindings: KeybindingsManager.create(), embedWorkingStatus: true)
        let currentTheme = theme
        editor.borderColor = { currentTheme.getThinkingBorderColor("high")($0) }
        let indicator = WorkingStatusIndicator(ui: ui, colorFn: { editor.borderColor($0) })
        defer { indicator.dispose() }
        editor.setWorkingStatusIndicator(indicator)
        let line = editor.render(width: 20)[0]
        #expect(renderingStripAnsi(line) == "── ⠋ Working ───────")
        #expect(line.contains(currentTheme.fg(.thinkingHigh, "⠋")))
        #expect(line.contains(currentTheme.fg(.thinkingHigh, "Working")))
    }

    @Test func standaloneEditorDoesNotEmbedWorkingIndicator() {
        let ui = TUI(terminal: RenderingTerminal())
        let indicator = WorkingStatusIndicator(ui: ui)
        defer { indicator.stop() }
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        editor.setWorkingStatusIndicator(indicator)
        #expect(!renderingStripAnsi(editor.render(width: 60)[0]).contains("Working"))
    }

    @Test func thinkingClickChangesOnlyItsRunAndGlobalChangeClearsOverrides() throws {
        let message = AssistantMessage(content: [
            .thinking(ThinkingContent(thinking: "first thought")), .text(TextContent(text: "middle")),
            .thinking(ThinkingContent(thinking: "second thought"))
        ], api: .anthropicMessages, provider: "anthropic", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        let component = AssistantMessageComponent(message: message)
        let content = try #require(component.children.first as? Container)
        let regions = content.children.compactMap { $0 as? MouseRegion }
        #expect(regions.count == 2)
        let event = TuiMouseEvent(type: .click, button: .left, x: 0, y: 0, screenX: 0, screenY: 0, width: 80, height: 1)
        #expect(regions[0].handleMouse(event)?.handled == true)
        var rendered = renderingStripAnsi(component.render(width: 80).joined(separator: "\n"))
        #expect(!rendered.contains("first thought"))
        #expect(rendered.contains("second thought"))
        component.setHideThinkingBlock(false)
        rendered = renderingStripAnsi(component.render(width: 80).joined(separator: "\n"))
        #expect(rendered.contains("first thought"))
        component.setHideThinkingBlock(true)
        #expect(!renderingStripAnsi(component.render(width: 80).joined(separator: "\n")).contains("second thought"))
    }

    @Test func fallbackToolOutputHasTenLinesAndClickExpands() throws {
        let ui = TUI(terminal: RenderingTerminal())
        let component = ToolExecutionComponent(toolName: "unknown", args: [:], ui: ui)
        let output = (1...15).map { "result-\($0)" }.joined(separator: "\n")
        component.updateResult(ToolResultMessage(toolCallId: "call", toolName: "unknown", content: [.text(TextContent(text: output))], isError: false))
        var rendered = renderingStripAnsi(component.render(width: 80).joined(separator: "\n"))
        #expect(rendered.contains("result-10"))
        #expect(!rendered.contains("result-11"))
        #expect(rendered.contains("5 more lines"))
        let region = try #require(component.children.compactMap { $0 as? MouseRegion }.first)
        let event = TuiMouseEvent(type: .click, button: .left, x: 0, y: 1, screenX: 0, screenY: 0, width: 80, height: 15)
        #expect(region.handleMouse(event)?.handled == true)
        rendered = renderingStripAnsi(component.render(width: 80).joined(separator: "\n"))
        #expect(rendered.contains("result-15"))
    }

    @Test func selfRenderedEmptyToolTakesNoRows() {
        var definition = CustomTool(name: "empty", label: "Empty", description: "", parameters: [:], execute: { _, _, _, _, _ in
            AgentToolResult(content: [], details: nil)
        }, renderCall: { _, _ in nil }, renderResult: { _, _, _ in nil })
        definition.renderShell = .self
        let component = ToolExecutionComponent(toolName: "empty", args: [:], customTool: definition, ui: TUI(terminal: RenderingTerminal()))
        #expect(component.render(width: 80).isEmpty)
    }

    @Test func fullscreenSearchStylesUseThemeAndHover() throws {
        let options = interactiveAltScreenOptions(copyOnSelect: false)
        #expect(!options.copyOnSelect)
        #expect(options.searchMatchStyle("match") == theme.underline(theme.bg(.searchMatchBg, theme.fg(.searchMatchText, "match"))))
        #expect(options.searchCurrentMatchStyle("match") == theme.bold(theme.inverse(theme.bg(.searchMatchBg, theme.fg(.searchMatchText, "match")))))
        #expect(options.searchNavigationButtonStyle("next", false) == "next")
        #expect(options.searchNavigationButtonStyle("next", true) == theme.underline("next"))
        let jumpIndicator = try #require(options.scrollToEndIndicator)
        let jumpLabel = jumpIndicator()
        #expect(jumpLabel.contains("Jump to latest message"))
    }

    @Test func themeOverrideTakesPriorityAndDoesNotPersist() async {
        var initialSettings = Settings()
        initialSettings.theme = "dark"
        let settings = SettingsManager.inMemory(initialSettings)
        var appliedNames: [String] = []
        let controller = InteractiveThemeController(ui: TUI(terminal: RenderingTerminal()), getSettingsManager: { settings }, showError: { _ in }, onChanged: { appliedNames.append(theme.name) }, initialThemeSetting: "light")
        defer { controller.dispose(); initTheme("dark") }
        await controller.applyFromSettings()
        #expect(controller.getThemeSelection() == "light")
        #expect(appliedNames.last == "light")
        #expect(settings.getTheme() == "dark")
        await controller.setThemeSetting("dark")
        #expect(controller.getThemeSelection() == "dark")
        settings.setTheme("light")
        await controller.applyFromSettings()
        #expect(appliedNames.last == "dark")
    }

    @Test func themePairFollowsReportsUntilDisposed() async {
        let terminal = RenderingTerminal()
        let ui = TUI(terminal: terminal)
        ui.start()
        defer { ui.stop(); initTheme("dark") }
        let settings = SettingsManager.inMemory()
        var appliedNames: [String] = []
        let controller = InteractiveThemeController(ui: ui, getSettingsManager: { settings }, showError: { _ in }, onChanged: { appliedNames.append(theme.name) }, initialThemeSetting: "light/dark")
        await controller.applyFromSettings()
        terminal.emit("\u{001B}[?997;2n")
        await Task.yield()
        await ui.waitForRender()
        await Task.yield()
        await ui.waitForRender()
        #expect(appliedNames.last == "light")
        terminal.emit("\u{001B}[?997;1n")
        await Task.yield()
        await ui.waitForRender()
        await Task.yield()
        await ui.waitForRender()
        #expect(appliedNames.last == "dark")
        controller.dispose()
        terminal.emit("\u{001B}[?997;2n")
        await Task.yield()
        await ui.waitForRender()
        await Task.yield()
        await ui.waitForRender()
        #expect(appliedNames.last == "dark")
        #expect(settings.getTheme() == nil)
    }

    @Test func themeSettingsReloadWithoutInitialOverride() async {
        let first = SettingsManager.inMemory()
        first.setTheme("dark")
        let second = SettingsManager.inMemory()
        second.setTheme("light")
        var current = first
        var appliedNames: [String] = []
        let controller = InteractiveThemeController(ui: TUI(terminal: RenderingTerminal()), getSettingsManager: { current }, showError: { _ in }, onChanged: { appliedNames.append(theme.name) })
        defer { controller.dispose(); initTheme("dark") }
        await controller.applyFromSettings()
        current = second
        await controller.applyFromSettings()
        #expect(appliedNames.last == "light")
        _ = controller.setThemeName("dark")
        await controller.applyFromSettings()
        #expect(appliedNames.last == "dark")
    }

    @Test func builtInRendererSlotsFillIndependently() throws {
        var definition = CustomTool(name: "read", label: "Read", description: "Read", parameters: [:], execute: { _, _, _, _, _ in
            AgentToolResult(content: [], details: nil)
        })
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("custom call", paddingX: 0, paddingY: 0) } }
        let first = try #require(withBuiltInRenderers("read", definition))
        let callRenderer = try #require(first.renderCall)
        let call = try callRenderer([:], theme, ToolRenderContext())
        #expect(call.render(width: 80).joined().contains("custom call") == true)
        let resultRenderer = try #require(first.renderResult)
        let result = try resultRenderer(AgentToolResult(content: [.text(TextContent(text: "body"))], details: nil), RenderResultOptions(expanded: true, isPartial: false), theme, ToolRenderContext(expanded: true))
        #expect(result.render(width: 80).joined().contains("body") == true)
        definition.renderCall = nil
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("custom result", paddingX: 0, paddingY: 0) } }
        let second = try #require(withBuiltInRenderers("read", definition))
        let inheritedRenderer = try #require(second.renderCall)
        let inherited = try inheritedRenderer(["file_path": AnyCodable("README.md")], theme, ToolRenderContext())
        #expect(inherited.render(width: 80).joined().contains("README.md") == true)
        #expect(withBuiltInRenderers("unknown", nil) == nil)
        #expect(withBuiltInRenderers("bash", nil)?.renderResult != nil)
    }

    @Test func autoThemeSettingRequiresExactlyTwoNonemptyNames() {
        #expect(parseAutoThemeSetting(" light / dark ")?.light == "light")
        #expect(parseAutoThemeSetting("light/dark")?.dark == "dark")
        #expect(parseAutoThemeSetting("a/b/c") == nil)
        #expect(parseAutoThemeSetting("/dark") == nil)
        #expect(parseAutoThemeSetting("dark") == nil)
    }
}

private func renderingStripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}
