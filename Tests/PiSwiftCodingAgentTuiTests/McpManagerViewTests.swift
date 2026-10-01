import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private enum McpViewTestError: LocalizedError {
    case waitExpired, managerFailed

    var errorDescription: String? {
        switch self {
        case .waitExpired: "fixture wait expired"
        case .managerFailed: "fixture manager failed"
        }
    }
}

@MainActor
private func waitForMcpView(_ check: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await check()) {
        guard ContinuousClock.now < deadline else { throw McpViewTestError.waitExpired }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func mcpViewText(_ view: McpManagerView, width: Int = 120) -> String {
    stripTerminalSequences(view.render(width: width).joined(separator: "\n"))
}

private func mcpViewMenu(_ values: [String], selected: String? = nil, title: String = "MCP servers") -> McpMenu {
    McpMenu(title: title, items: values.map { McpMenuItem(value: $0, label: $0, detail: "detail \($0)") },
            selected: selected, confirmLabel: "manage", cancelLabel: "close")
}

private actor McpViewModel {
    var model: McpMenu
    private(set) var builds = 0
    init(_ model: McpMenu) { self.model = model }
    func build() -> McpMenu { builds += 1; return model }
    func set(_ model: McpMenu) { self.model = model }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct McpManagerViewTests {
    @Test func initialAndStatusFramesMatchUpstream() {
        let redraws = Mutex(0)
        let view = McpManagerView(theme: theme, requestRender: { redraws.withLock { $0 += 1 } })
        #expect(mcpViewText(view).contains("MCP servers"))
        #expect(mcpViewText(view).contains("Loading…"))
        view.status(title: "Sign in to docs", message: "Contacting the authorization server…")
        let output = mcpViewText(view)
        #expect(output.contains("Sign in to docs"))
        #expect(output.contains("Contacting the authorization server…"))
        #expect(!output.contains("Loading…"))
        #expect(!output.contains("enter"))
        view.handleInput("\r")
        #expect(redraws.withLock { $0 } >= 2)
    }

    @Test func menuRendersDetailsErrorsAndInitialSelection() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let model = McpMenu(title: "MCP server docs", details: "https://example.com/mcp\nglobal: /tmp/mcp.json",
                            error: "connection failed\nserver stderr", items: [McpMenuItem(value: "tools", label: "Tools", detail: "2 offered"), McpMenuItem(value: "reconnect", label: "Reconnect")],
                            selected: "reconnect", confirmLabel: "select", cancelLabel: "back")
        let task = Task { await view.menu(model) }
        defer { task.cancel(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("connection failed") }
        let output = mcpViewText(view)
        #expect(output.contains("https://example.com/mcp"))
        #expect(output.contains("server stderr"))
        #expect(output.contains("2 offered"))
        #expect(output.contains("→ Reconnect"))
        #expect(output.contains("enter select • escape/ctrl+c back"))
        view.handleInput("\r")
        #expect(await task.value == "reconnect")
    }

    @Test func liveMenuKeepsUserSelectionByValueAfterReorder() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let state = McpViewModel(mcpViewMenu(["a", "b", "c"]))
        let changes = AsyncStream<Void>.makeStream()
        let terminated = Mutex(false)
        changes.continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        let task = Task { await view.menu(build: { await state.build() }, changes: changes.stream) }
        defer { task.cancel(); changes.continuation.finish(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("→ a") }
        view.handleInput("\u{001B}[B")
        #expect(mcpViewText(view).contains("→ b"))
        await state.set(mcpViewMenu(["c", "a", "b"], selected: "c", title: "Updated servers"))
        changes.continuation.yield(())
        try await waitForMcpView { mcpViewText(view).contains("Updated servers") }
        #expect(mcpViewText(view).contains("→ b"))
        view.handleInput("\r")
        #expect(await task.value == "b")
        try await waitForMcpView { terminated.withLock { $0 } }
        let count = await state.builds
        changes.continuation.yield(())
        await Task.yield()
        #expect(await state.builds == count)
    }

    @Test func removedSelectionFallsBackToFirstItem() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let state = McpViewModel(mcpViewMenu(["a", "b"], selected: "b"))
        let changes = AsyncStream<Void>.makeStream()
        let task = Task { await view.menu(build: { await state.build() }, changes: changes.stream) }
        defer { task.cancel(); changes.continuation.finish(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("→ b") }
        await state.set(mcpViewMenu(["c", "a"], selected: "a", title: "Removed server"))
        changes.continuation.yield(())
        try await waitForMcpView { mcpViewText(view).contains("Removed server") }
        #expect(mcpViewText(view).contains("→ c"))
        view.handleInput("\r")
        #expect(await task.value == "c")
    }

    @Test func emptyMenuHasCancelHintAndIgnoresConfirm() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let model = McpMenu(title: "Empty servers", items: [], empty: "No MCP servers configured.", confirmLabel: "manage", cancelLabel: "close")
        let completed = Mutex(false)
        let task = Task { let result = await view.menu(model); completed.withLock { $0 = true }; return result }
        defer { task.cancel(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("Empty servers") }
        #expect(mcpViewText(view).contains("No MCP servers configured."))
        #expect(!mcpViewText(view).contains("enter manage"))
        view.handleInput("\r")
        await Task.yield()
        #expect(!completed.withLock { $0 })
        view.handleInput("\u{001B}")
        #expect(await task.value == nil)
    }

    @Test func menuLimitsVisibleItemsAndClipsNarrowFrames() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let task = Task { await view.menu(mcpViewMenu((0..<20).map { "server-\($0)" })) }
        defer { task.cancel(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("server-0") }
        #expect(mcpViewText(view).split(separator: "\n").filter { $0.contains("detail server-") }.count == 12)
        #expect(mcpViewText(view).contains("(1/20)"))
        for _ in 0..<19 { view.handleInput("\u{001B}[B") }
        #expect(mcpViewText(view).contains("→ server-19"))
        #expect(mcpViewText(view).contains("(20/20)"))
        #expect(view.render(width: 8).allSatisfy { visibleWidth($0) <= 8 })
        view.handleInput("\u{001B}")
        #expect(await task.value == nil)
    }

    @Test func menuTaskCancellationStopsChangeConsumer() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let changes = AsyncStream<Void>.makeStream()
        let stopped = Mutex(false)
        changes.continuation.onTermination = { _ in stopped.withLock { $0 = true } }
        let task = Task { await view.menu(build: { mcpViewMenu(["docs"]) }, changes: changes.stream) }
        defer { task.cancel(); changes.continuation.finish(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("→ docs") }
        task.cancel()
        #expect(await task.value == nil)
        try await waitForMcpView { stopped.withLock { $0 } }
    }

    @Test func redirectPromptAcceptsTrimmedPastedURLAndIgnoresEmptySubmit() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        view.focused = true
        let completed = Mutex(false)
        let authorizationURL = URL(string: "https://example.com/oauth/authorize")!
        let task = Task { let result = await view.redirectURL(title: "Sign in to docs", authorizationURL: authorizationURL); completed.withLock { $0 = true }; return result }
        defer { task.cancel(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains(authorizationURL.absoluteString) }
        #expect(mcpViewText(view).contains("Approve access in your browser. If it did not open, visit:"))
        #expect(mcpViewText(view).contains("paste the URL it was redirected to:"))
        #expect(mcpViewText(view).contains("enter submit • escape/ctrl+c cancel"))
        view.handleInput("\r")
        await Task.yield()
        #expect(!completed.withLock { $0 })
        let callback = "http://127.0.0.1:8765/callback?code=test&state=fixture"
        view.handleInput("\u{001B}[200~  \(callback)  \u{001B}[201~")
        view.handleInput("\r")
        #expect(await task.value?.absoluteString == callback)
        view.status(title: "Sign in to docs", message: "Connecting…")
        #expect(mcpViewText(view).contains("Connecting…"))
        #expect(!mcpViewText(view).contains(authorizationURL.absoluteString))
    }

    @Test(arguments: [false, true]) func redirectPromptCancelsForKeyOrBrowserCallback(_ browserCallback: Bool) async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let task = Task { await view.redirectURL(title: "Sign in", authorizationURL: URL(string: "https://example.com/authorize")!) }
        defer { task.cancel(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("https://example.com/authorize") }
        if browserCallback { task.cancel() }
        else { view.handleInput("\u{001B}") }
        #expect(await task.value == nil)
    }
}

private final class McpViewTerminal: Terminal {
    var columns = 120
    var rows = 30
    var kittyProtocolActive = false
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {}
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

private final class McpViewResourceLoader: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

@MainActor
private struct McpMountedHost {
    let session: AgentSession
    let runner: HookRunner
    let tui: TUI
    let mode: InteractiveMode
    let editor: CustomEditor
    let bridge: InteractiveMcpUi

    init(bridge: InteractiveMcpUi, command: RegisteredCommand) {
        self.bridge = bridge
        let model = Model(id: "test", name: "test", api: .anthropicMessages, provider: "anthropic", baseUrl: "https://example.invalid", reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 20_000)
        let state = AgentState(systemPrompt: "", model: model, thinkingLevel: .off, tools: [], messages: [])
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        runner = HookRunner([LoadedHook(path: "builtin:mcp", resolvedPath: "builtin:mcp", handlers: [:], commands: ["mcp": command])], "/tmp", manager, registry)
        session = AgentSession(config: AgentSessionConfig(agent: Agent(AgentOptions(initialState: state)), sessionManager: manager, settingsManager: .inMemory(), resourceLoader: McpViewResourceLoader(), hookRunner: runner, modelRegistry: registry))
        tui = TUI(terminal: McpViewTerminal())
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        mode = InteractiveMode(session: session, tui: tui, editor: editor, mcpUi: bridge)
    }

    func close() { bridge.cancelManager(); session.dispose() }
}

private actor McpBlockedBuild {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

extension McpManagerViewTests {
    @Test func cancellationDuringRebuildPreventsStaleRedraw() async throws {
        let view = McpManagerView(theme: theme, requestRender: {})
        let gate = McpBlockedBuild()
        let builds = Mutex(0)
        let changes = AsyncStream<Void>.makeStream()
        let task = Task { await view.menu(build: {
            let count = builds.withLock { $0 += 1; return $0 }
            if count > 1 { await gate.wait(); return mcpViewMenu(["stale"], title: "Stale redraw") }
            return mcpViewMenu(["docs"])
        }, changes: changes.stream) }
        defer { task.cancel(); changes.continuation.finish(); view.dispose() }
        try await waitForMcpView { mcpViewText(view).contains("→ docs") }
        changes.continuation.yield(())
        try await waitForMcpView { await gate.started }
        task.cancel()
        #expect(await task.value == nil)
        view.status(title: "Next screen", message: "Ready")
        await gate.release()
        await Task.yield()
        #expect(mcpViewText(view).contains("Next screen"))
        #expect(!mcpViewText(view).contains("Stale redraw"))
    }

    @Test func mountedManagerKeepsOneViewAndRestoresEditor() async throws {
        let bridge = InteractiveMcpUi()
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { _, _ in
            guard await bridge.menu(mcpViewMenu(["docs"])) != nil else { return }
            await bridge.status(title: "MCP server docs", message: "Reconnecting…")
            _ = await bridge.menu(mcpViewMenu(["tools"], title: "MCP server docs"))
        }
        let host = McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.editor.setText("saved input")
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        let task = Task { await host.mode.handleHookCommand("/mcp") }
        defer { task.cancel() }
        try await waitForMcpView { host.tui.getFocusedComponent() is McpManagerView }
        let view = try #require(host.tui.getFocusedComponent() as? McpManagerView)
        try await waitForMcpView { mcpViewText(view).contains("→ docs") }
        view.handleInput("\r")
        try await waitForMcpView { mcpViewText(view).contains("→ tools") }
        #expect(host.tui.getFocusedComponent() === view)
        view.handleInput("\u{001B}")
        #expect(await task.value)
        #expect(host.tui.getFocusedComponent() === host.editor)
        #expect(host.editor.getText() == "saved input")
    }

    @Test func mountedManagerCancellationRestoresEditorAndEndsOperation() async throws {
        let bridge = InteractiveMcpUi()
        let completed = Mutex(false)
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { _, _ in
            _ = await bridge.menu(mcpViewMenu(["docs"]))
            completed.withLock { $0 = true }
        }
        let host = McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        let task = Task { await host.mode.handleHookCommand("/mcp") }
        defer { task.cancel() }
        try await waitForMcpView { host.tui.getFocusedComponent() is McpManagerView }
        task.cancel()
        #expect(await task.value)
        #expect(completed.withLock { $0 })
        #expect(host.tui.getFocusedComponent() === host.editor)
    }

    @Test func initialBareMcpPromptUsesManagerScope() async throws {
        let bridge = InteractiveMcpUi()
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { _, _ in
            _ = await bridge.menu(mcpViewMenu(["docs"]))
        }
        let host = McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        let task = Task { await host.mode.prompt(" /mcp \n", images: nil) }
        defer { task.cancel() }
        try await waitForMcpView { host.tui.getFocusedComponent() is McpManagerView }
        let view = try #require(host.tui.getFocusedComponent() as? McpManagerView)
        try await waitForMcpView { mcpViewText(view).contains("→ docs") }
        view.handleInput("\u{001B}")
        await task.value
        #expect(host.tui.getFocusedComponent() === host.editor)
    }

    @Test func mountedManagerErrorReportsAndRestoresEditor() async throws {
        let bridge = InteractiveMcpUi()
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { _, _ in throw McpViewTestError.managerFailed }
        let host = McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        #expect(await host.mode.handleHookCommand("/mcp"))
        #expect(host.tui.getFocusedComponent() === host.editor)
        #expect(host.mode.chatContainer.render(width: 120).joined().contains(McpViewTestError.managerFailed.localizedDescription))
    }

    @Test func replacementCommandAndExplicitActionUseNormalHookPath() async {
        let bridge = InteractiveMcpUi()
        let argsSeen = Mutex<[String]>([])
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "/tmp/custom-mcp.swift", source: "extension", scope: "user")) { args, _ in argsSeen.withLock { $0.append(args) } }
        let host = McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        #expect(await host.mode.handleHookCommand("/mcp"))
        #expect(await host.mode.handleHookCommand("/mcp login docs"))
        #expect(argsSeen.withLock { $0 } == ["", "login docs"])
        #expect(host.tui.getFocusedComponent() === host.editor)
    }
}
