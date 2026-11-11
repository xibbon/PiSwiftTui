import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private func pt1Session(_ id: String, name: String? = nil, text: String = "", cwd: String = "", modified: Double = 0) -> SessionInfo {
    SessionInfo(path: "/tmp/\(id).jsonl", id: id, cwd: cwd, name: name,
        created: .distantPast, modified: Date(timeIntervalSince1970: modified), messageCount: 1,
        firstMessage: text, allMessagesText: text)
}

private final class PT1SelectorTerminal: Terminal {
    var columns = 120
    var rows = 40
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

@Suite @MainActor struct PT1SelectorTests {
    @Test("relevance sort orders by score and tie-breaks by modified desc")
    func relevanceOrder() {
        let sessions = [pt1Session("old", name: "build", modified: 1), pt1Session("new", name: "build", modified: 2)]
        #expect(filterSessionSearch(sessions, query: "build").map(\.id) == ["new", "old"])
    }

    @Test("ignores the position of a match in message text")
    func messagePosition() {
        let sessions = [pt1Session("first", text: "build", modified: 1), pt1Session("second", text: "prefix build", modified: 2)]
        #expect(filterSessionSearch(sessions, query: "build").map(\.id) == ["second", "first"])
    }

    @Test("does not match scattered characters in session ids or messages")
    func scatteredIDs() {
        #expect(filterSessionSearch([pt1Session("1a0b2c4", text: "1a0b2c4")], query: "1024").isEmpty)
    }

    @Test("ranks name text, then message text, then scattered name matches")
    func fieldTiers() {
        let sessions = [pt1Session("fuzzy", name: "b_u_i_l_d"), pt1Session("message", text: "build"), pt1Session("name", name: "build")]
        #expect(filterSessionSearch(sessions, query: "build").map(\.id) == ["name", "message", "fuzzy"])
    }

    @Test("matches each token within a single field")
    func fieldBoundaries() {
        let sessions = [pt1Session("x", name: "foo", text: "bar")]
        #expect(filterSessionSearch(sessions, query: "foobar").isEmpty)
        #expect(filterSessionSearch(sessions, query: "foo bar").count == 1)
    }

    @Test("ranks regex name matches first and rejects invalid regex")
    func regexNames() {
        let sessions = [pt1Session("message", text: "BUILD"), pt1Session("name", name: "build")]
        #expect(filterSessionSearch(sessions, query: "re:build").map(\.id) == ["name", "message"])
        #expect(filterSessionSearch(sessions, query: "re:[").isEmpty)
        #expect(filterSessionSearch(sessions, query: "re:").isEmpty)
    }

    @Test("filters by quoted phrase with whitespace normalization")
    func quotedPhrases() {
        #expect(filterSessionSearch([pt1Session("a", text: "node\n  cve")], query: "\"node cve\"").count == 1)
    }

    @Test("hides names that restate the ID and shows names with extra words")
    func distinctNames() {
        #expect(getDistinctModelName(id: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0", name: "Claude Sonnet 4.5 (EU)") == nil)
        #expect(getDistinctModelName(id: "minimax/minimax-m3", name: "MiniMax M3 [custom]") == "MiniMax M3 [custom]")
        #expect(getDistinctModelName(id: "mistral-small-2603", name: "Mistral Small 4") == "Mistral Small 4")
        #expect(getDistinctModelName(id: "模型-版本", name: "模型 版本") == nil)
    }

    @Test("orders implemented preferred partners first in rows and completions")
    func providerOrder() {
        let options = [AuthSelectorProvider(id: "a", name: "Alpha", authType: .apiKey),
            AuthSelectorProvider(id: "openrouter", name: "OpenRouter", authType: .apiKey),
            AuthSelectorProvider(id: "z", name: "Zulu", authType: .apiKey)]
        #expect(getLoginProviderCompletionOptions(options).map(\.value) == ["openrouter", "a", "z"])
        var selected = ""
        let selector = OAuthSelectorComponent(mode: .login, providers: options,
            onSelect: { id, _ in selected = id }, onCancel: {})
        defer { selector.closeSelector() }
        #expect(stripTerminalSequences(selector.render(width: 100).joined()).contains("OpenRouter ✦"))
        selector.handleInput("\r")
        #expect(selected == "openrouter")
        #expect(openRouterProviderBrand("OpenRouter", elapsedMilliseconds: 0) != openRouterProviderBrand("OpenRouter", elapsedMilliseconds: 1200))
    }

    @Test("provider and session page moves use the visible page and clamp empty lists")
    func pages() {
        let providers = (0..<12).map { AuthSelectorProvider(id: String(format: "%02d", $0), name: String(format: "%02d", $0), authType: .apiKey) }
        var selected = ""
        let selector = OAuthSelectorComponent(mode: .login, providers: providers,
            onSelect: { id, _ in selected = id }, onCancel: {})
        defer { selector.closeSelector() }
        selector.handleInput("\u{1b}[6~")
        selector.handleInput("\r")
        #expect(selected == "08")
        let sessions = SessionList(sessions: (0..<12).map { pt1Session("s\($0)") }, showCwd: false)
        sessions.onSelect = { selected = $0 }
        sessions.handleInput("\u{1b}[6~")
        sessions.handleInput("\r")
        #expect(selected == "/tmp/s5.jsonl")
        let empty = SessionList(sessions: [], showCwd: false)
        empty.handleInput("\u{1b}[6~")
        empty.handleInput("\r")
        #expect((sessions as any Component).capturesViewportInput)
    }

    @Test("shows the tree search cursor and transfers it to label editing")
    func treeCursor() {
        let entry = SessionMessageEntry(id: "u", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
            message: .user(UserMessage(content: .text("hello"), timestamp: 0)))
        let tree = TreeSelectorComponent(tree: [SessionTreeNode(entry: .message(entry), children: [], label: nil)],
            currentLeafId: "u", terminalHeight: 24, onSelect: { _ in }, onCancel: {})
        tree.focused = true
        tree.handleInput("he")
        let lines = tree.render(width: 60)
        #expect(stripTerminalSequences(lines.joined()).contains("Search: he"))
        #expect(lines.joined().filter { $0 == "\0" }.count == 1)
        tree.handleInput("l")
        let labelLines = tree.render(width: 60)
        #expect(labelLines.joined().filter { $0 == "\0" }.count == 1)
        tree.handleInput("\u{1b}")
        #expect(tree.render(width: 60).joined().filter { $0 == "\0" }.count == 1)
        tree.focused = false
        #expect(!tree.render(width: 60).joined().contains("\0"))
        #expect(tree.getTreeList().capturesViewportInput)
    }

    @Test("keeps selection on the browsed model when snapshot rows change")
    func refreshSelection() async throws {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        func register(_ ids: [String]) {
            registry.registerProvider(HookProviderConfig(provider: "pt1", api: .openAIResponses,
                baseUrl: "https://example.invalid", apiKey: "test", models: ids.map { HookProviderModel(id: $0) }), sourceId: "pt1")
        }
        register(["current", "browsed"])
        let current = try #require(registry.find("pt1", "current"))
        var selected = ""
        let selector = ModelSelectorComponent(tui: TUI(terminal: PT1SelectorTerminal()), currentModel: current,
            modelRegistry: registry, scopedModels: [], onSelect: { selected = $0.id }, onCancel: {})
        selector.closeSelector()
        await selector.loadModelsFromSnapshot()
        selector.handleInput("pt1")
        selector.handleInput("\u{1b}[B")
        register(["current", "inserted", "browsed"])
        await selector.loadModelsFromSnapshot()
        selector.handleInput("\r")
        #expect(selected == "browsed")
        register(["current"])
        await selector.loadModelsFromSnapshot()
        selector.handleInput("\r")
        #expect(selected == "current")
    }
    @Test("shows distinct names in both model selectors and moves one model page")
    func modelNamesAndPages() {
        let models = (0..<12).map { index in
            Model(id: "model-\(index)", name: index == 0 ? "Custom title" : "Model \(index)",
                api: .openAIResponses, provider: "pt1", baseUrl: "https://example.invalid", reasoning: false,
                input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                contextWindow: 1000, maxTokens: 100)
        }
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        var selected = ""
        let selector = ModelSelectorComponent(tui: TUI(terminal: PT1SelectorTerminal()), currentModel: models[0],
            modelRegistry: registry, scopedModels: models.map { ScopedModel(model: $0) },
            onSelect: { selected = $0.id }, onCancel: {})
        defer { selector.closeSelector() }
        #expect(stripTerminalSequences(selector.render(width: 100).joined()).contains("model-0 (Custom title)"))
        selector.handleInput("\u{1b}[6~")
        selector.handleInput("\r")
        #expect(selected == "model-10")
        let scoped = ScopedModelsSelectorComponent(config: ModelsConfig(allModels: models,
            enabledModelIds: [], hasEnabledModelsFilter: false),
            callbacks: ModelsCallbacks(onChange: { _ in }, onPersist: { _ in }, onCancel: {}))
        defer { scoped.closeSelector() }
        #expect(stripTerminalSequences(scoped.render(width: 100).joined()).contains("model-0 (Custom title)"))
    }

}
