import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

@MainActor
private final class T3bStartupMcpUi: McpUi {
    var titles: [String] = []

    func menu(_ menu: McpMenu) async -> String? {
        titles.append(menu.title)
        return nil
    }

    func status(title: String, message: String) {}
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

@Test(.timeLimit(.minutes(1)), arguments: [HookMode.tui, .print, .rpc])
@MainActor
func t3bStartupMcpHostIsUsedOnlyInInteractiveMode(_ mode: HookMode) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-t3b-startup-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ui = T3bStartupMcpUi()
    let extensions = startupBuiltinExtensions(agentDir: root, mcpUi: ui)
    let mcp = try #require(extensions.first { $0.name == "mcp" })
    let hook = try #require(ExtensionLoader.load(mcp, cwd: root.path, eventBus: createEventBus()).hook)
    let command = try #require(hook.commands["mcp"])
    let manager = SessionManager.inMemory(root.path)
    let registry = ModelRegistry(AuthStorage.inMemory(), nil,
                                 modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let context = HookCommandContext(
        ui: NoOpHookUIContext(), mode: mode, hasUI: mode == .tui, cwd: root.path,
        sessionManager: manager, modelRegistry: registry, model: { nil }, systemPrompt: { nil },
        isIdle: { true }, abort: {}, hasPendingMessages: { false }, waitForIdle: {},
        newSession: { _ in HookCommandResult(cancelled: false) },
        fork: { _ in HookCommandResult(cancelled: false) },
        navigateTree: { _, _ in HookCommandResult(cancelled: false) }
    )
    try await command.handler("", context)
    #expect(ui.titles == (mode == .tui ? ["MCP servers"] : []))
}
