import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private enum T2McpWaitError: LocalizedError {
    case waitExpired, managerFailed

    var errorDescription: String? {
        switch self {
        case .waitExpired: "fixture wait expired"
        case .managerFailed: "fixture manager failed"
        }
    }
}

@MainActor
private func waitForT2McpView(_ check: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await check()) {
        guard ContinuousClock.now < deadline else { throw T2McpWaitError.waitExpired }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func t2McpViewText(_ view: McpManagerView, width: Int = 120) -> String {
    stripTerminalSequences(view.render(width: width).joined(separator: "\n"))
}

private final class T2McpTerminal: Terminal {
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

private final class T2McpResourceLoader: ResourceLoader {
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
private struct T2McpMountedHost {
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
        session = AgentSession(config: AgentSessionConfig(agent: Agent(AgentOptions(initialState: state)), sessionManager: manager, settingsManager: .inMemory(), resourceLoader: T2McpResourceLoader(), hookRunner: runner, modelRegistry: registry))
        tui = TUI(terminal: T2McpTerminal())
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        mode = InteractiveMode(session: session, tui: tui, editor: editor, mcpUi: bridge)
    }

    func close() { bridge.cancelManager(); session.dispose() }
}

@Suite("T2 mounted MCP login", .timeLimit(.minutes(1))) @MainActor
struct T2McpLoginManagerTests {
    @Test(arguments: [false, true]) func loginCommandMountsManager(_ initialPrompt: Bool) async throws {
        let bridge = InteractiveMcpUi()
        let argsSeen = Mutex<[String]>([])
        let command = RegisteredCommand(name: "mcp", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { args, _ in
            argsSeen.withLock { $0.append(args) }
            _ = await bridge.redirectURL(title: "Sign in to docs", authorizationURL: URL(string: "https://example.com/authorize")!)
        }
        let host = T2McpMountedHost(bridge: bridge, command: command)
        defer { host.close() }
        host.editor.setText("saved input")
        host.tui.setFocus(host.editor)
        await host.mode.initializeHooksAndCustomTools()
        let task = Task {
            if initialPrompt { await host.mode.prompt(" /mcp login docs \n", images: nil) }
            else { #expect(await host.mode.handleHookCommand("/mcp login docs")) }
        }
        defer { task.cancel() }
        try await waitForT2McpView { host.tui.getFocusedComponent() is McpManagerView }
        let view = try #require(host.tui.getFocusedComponent() as? McpManagerView)
        try await waitForT2McpView { t2McpViewText(view).contains("https://example.com/authorize") }
        #expect(t2McpViewText(view).contains("to copy"))
        #expect(argsSeen.withLock { $0 } == ["login docs"])
        view.handleInput("\u{001B}")
        await task.value
        #expect(host.tui.getFocusedComponent() === host.editor)
        #expect(host.editor.getText() == "saved input")
    }

}
