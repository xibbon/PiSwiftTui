import Foundation
import MiniTui
import PiSwiftAI
@testable import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class ControlsResourceLoader: ResourceLoader {
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

private final class ControlsTerminal: Terminal {
    var columns = 100
    var rows = 24
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

private final class ControlsProvider: AutocompleteProvider {
    let base: any AutocompleteProvider
    let value: String

    init(base: any AutocompleteProvider, value: String) {
        self.base = base
        self.value = value
    }

    func getSuggestions(lines: [String], cursorLine: Int, cursorCol: Int, signal: CancellationSignal?) -> (items: [AutocompleteItem], prefix: String)? {
        let previous = base.getSuggestions(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol, signal: signal)
        return ((previous?.items ?? []) + [AutocompleteItem(value: value, label: value)], previous?.prefix ?? "")
    }

    func applyCompletion(lines: [String], cursorLine: Int, cursorCol: Int, item: AutocompleteItem, prefix: String) -> (lines: [String], cursorLine: Int, cursorCol: Int) {
        base.applyCompletion(lines: lines, cursorLine: cursorLine, cursorCol: cursorCol, item: item, prefix: prefix)
    }
}

@MainActor
private struct ControlsHost {
    let session: AgentSession
    let runner: HookRunner
    let mode: InteractiveMode
    let editor: CustomEditor

    init(streaming: Bool = false, embedded: Bool = false, reloadExtensions: (@Sendable () async -> LoadExtensionsResult)? = nil) {
        let model = Model(id: "test", name: "test", api: .anthropicMessages, provider: "anthropic", baseUrl: "https://example.invalid", reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 20_000)
        let state = AgentState(systemPrompt: "", model: model, thinkingLevel: .off, tools: [], messages: [], isStreaming: streaming, streamingMessage: nil, pendingToolCalls: [], errorMessage: nil)
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        runner = HookRunner([], "/tmp", manager, registry)
        session = AgentSession(config: AgentSessionConfig(agent: Agent(AgentOptions(initialState: state)), sessionManager: manager, settingsManager: .inMemory(), resourceLoader: ControlsResourceLoader(), hookRunner: runner, modelRegistry: registry, reloadExtensionsHook: reloadExtensions))
        let tui = TUI(terminal: ControlsTerminal())
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory(), embedWorkingStatus: embedded)
        mode = InteractiveMode(session: session, tui: tui, editor: editor)
    }

    func close() {
        mode.handleAgentEvent(.agentEnd(messages: []))
        session.dispose()
    }

    var transcript: String { mode.chatContainer.render(width: 160).joined(separator: "\n") }
    var status: String { mode.statusContainer?.render(width: 160).joined(separator: "\n") ?? "" }
    var editorText: String { editor.render(width: 100).joined(separator: "\n") }
    var suggestions: [String] {
        mode.stackedAutocompleteProvider?.getSuggestions(lines: [""], cursorLine: 0, cursorCol: 0)?.items.map(\.value) ?? []
    }
}

private func controlsThinkingMessage() -> AssistantMessage {
    AssistantMessage(content: [.thinking(ThinkingContent(thinking: "private thought")), .text(TextContent(text: "answer"))], api: .anthropicMessages, provider: "anthropic", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
}

@MainActor
@Suite struct ExtensionUIControlsTests {
    @Test(arguments: [false, true])
    func visibilityRemovesAndRestoresIndicator(_ embedded: Bool) async throws {
        let host = ControlsHost(streaming: true, embedded: embedded)
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let ui = host.runner.getUIContext()
        host.mode.handleAgentEvent(.turnStart)
        let loader = try #require(host.mode.loadingAnimation)
        #expect(host.editorText.contains("Working") == embedded)
        #expect(host.status.contains("Working") == !embedded)

        ui.setWorkingVisible(false)
        #expect(!host.editorText.contains("Working"))
        #expect(!host.status.contains("Working"))
        #expect(host.mode.loadingAnimation === loader)
        ui.setWorkingVisible(true)
        #expect(host.mode.loadingAnimation === loader)
        #expect(host.editorText.contains("Working") == embedded)
        #expect(host.status.contains("Working") == !embedded)

        ui.setWorkingVisible(false)
        host.mode.handleAgentEvent(.agentEnd(messages: []))
        host.mode.handleAgentEvent(.turnStart)
        #expect(host.mode.loadingAnimation != nil)
        #expect(!host.mode.activeWorkingIndicatorEmbedded)
        #expect(!host.editorText.contains("Working"))
        #expect(!host.status.contains("Working"))
    }

    @Test func indicatorChangesAndRestoresDefaults() async throws {
        let host = ControlsHost(streaming: true, embedded: true)
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let ui = host.runner.getUIContext()
        host.mode.handleAgentEvent(.turnStart)
        let defaultIndicator = try #require(host.mode.loadingAnimation).getRenderedIndicator()
        ui.setWorkingIndicator(WorkingIndicatorOptions(frames: ["a", "b"], intervalMs: 60_000))
        #expect(host.mode.loadingAnimation?.getRenderedIndicator() == "a")
        #expect(host.editorText.contains("a"))
        host.mode.handleAgentEvent(.agentEnd(messages: []))
        host.mode.handleAgentEvent(.turnStart)
        #expect(host.mode.loadingAnimation?.getRenderedIndicator() == "a")
        ui.setWorkingIndicator(nil)
        #expect(host.mode.loadingAnimation?.getRenderedIndicator() == defaultIndicator)
        #expect(host.mode.workingIndicatorOptions == nil)
        #expect(host.mode.activeWorkingIndicatorEmbedded)
    }

    @Test func thinkingLabelUpdatesExistingAndStreamingMessages() async throws {
        let host = ControlsHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        host.mode.toggleThinkingBlockVisibility()
        let message = controlsThinkingMessage()
        _ = host.session.sessionManager.appendMessage(.assistant(message))
        host.mode.renderInitialMessages()
        host.mode.handleAgentEvent(.messageStart(message: .assistant(message)))
        let components = host.mode.chatContainer.children.compactMap { $0 as? AssistantMessageComponent }
        #expect(components.count == 2)
        host.runner.getUIContext().setHiddenThinkingLabel("Pondering")
        for component in components {
            let output = component.render(width: 120).joined()
            #expect(output.contains("Pondering"))
            #expect(!output.contains("Thinking..."))
        }
        host.runner.getUIContext().setHiddenThinkingLabel(nil)
        for component in components {
            let output = component.render(width: 120).joined()
            #expect(output.contains("Thinking..."))
            #expect(!output.contains("Pondering"))
        }
    }

    @Test func newAssistantMessagesUseStoredThinkingLabel() async {
        let host = ControlsHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        host.mode.toggleThinkingBlockVisibility()
        host.runner.getUIContext().setHiddenThinkingLabel("Pondering")
        let message = controlsThinkingMessage()
        _ = host.session.sessionManager.appendMessage(.assistant(message))
        host.mode.renderInitialMessages()
        host.mode.handleAgentEvent(.messageStart(message: .assistant(message)))
        let components = host.mode.chatContainer.children.compactMap { $0 as? AssistantMessageComponent }
        #expect(components.count == 2)
        for component in components {
            #expect(component.render(width: 120).joined().contains("Pondering"))
        }
    }

    @Test func autocompleteFactoriesStackInOrder() async {
        let host = ControlsHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let ui = host.runner.getUIContext()
        ui.addAutocompleteProvider { base in
            guard let provider = base as? any AutocompleteProvider else { return base }
            return ControlsProvider(base: provider, value: "first-wrapper")
        }
        ui.addAutocompleteProvider { base in
            guard let provider = base as? any AutocompleteProvider else { return base }
            return ControlsProvider(base: provider, value: "second-wrapper")
        }
        #expect(Array(host.suggestions.suffix(2)) == ["first-wrapper", "second-wrapper"])
    }

    @Test func invalidAutocompleteFactoryKeepsProviderAndShowsWarning() async {
        let host = ControlsHost()
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let ui = host.runner.getUIContext()
        ui.addAutocompleteProvider { base in
            guard let provider = base as? any AutocompleteProvider else { return base }
            return ControlsProvider(base: provider, value: "valid-wrapper")
        }
        let before = host.suggestions
        ui.addAutocompleteProvider { _ in "wrong type" }
        #expect(host.suggestions == before)
        #expect(host.transcript.lowercased().contains("autocomplete"))
        #expect(host.transcript.lowercased().contains("warning"))
    }

    @Test func reloadResetsExtensionControlsAndLiveLoader() async throws {
        let reloadCount = Mutex(0)
        let host = ControlsHost(reloadExtensions: {
            reloadCount.withLock { $0 += 1 }
            return LoadExtensionsResult(hooks: [])
        })
        defer { host.close() }
        await host.mode.initializeHooksAndCustomTools()
        let ui = host.runner.getUIContext()
        host.mode.handleAgentEvent(.turnStart)
        let defaultIndicator = try #require(host.mode.loadingAnimation).getRenderedIndicator()
        ui.setWorkingVisible(false)
        ui.setWorkingIndicator(WorkingIndicatorOptions(frames: ["custom-frame"], intervalMs: 60_000))
        ui.setWorkingMessage("Extension work")
        ui.setHiddenThinkingLabel("Pondering")
        ui.addAutocompleteProvider { base in
            guard let provider = base as? any AutocompleteProvider else { return base }
            return ControlsProvider(base: provider, value: "reload-wrapper")
        }
        for _ in 0..<20 where host.mode.loadingAnimation?.render(width: 120).joined().contains("Extension work") != true {
            await Task.yield()
        }
        #expect(host.mode.loadingAnimation?.render(width: 120).joined().contains("Extension work") == true)
        #expect(host.suggestions.contains("reload-wrapper"))
        await host.mode.handleReloadCommand()
        #expect(reloadCount.withLock { $0 } == 1)
        #expect(host.session.hookRunner === host.runner)
        #expect(host.mode.workingVisible)
        #expect(host.mode.workingIndicatorOptions == nil)
        #expect(host.mode.hiddenThinkingLabel == nil)
        #expect(host.mode.loadingAnimation?.getRenderedIndicator() == defaultIndicator)
        #expect(host.mode.loadingAnimation?.render(width: 120).joined().contains("Working") == true)
        #expect(host.mode.loadingAnimation?.render(width: 120).joined().contains("Extension work") == false)
        #expect(!host.suggestions.contains("reload-wrapper"))
        host.mode.handleAgentEvent(.agentEnd(messages: []))
        host.mode.handleAgentEvent(.turnStart)
        #expect(host.status.contains("Working"))
        #expect(host.mode.loadingAnimation?.getRenderedIndicator() == defaultIndicator)
    }
}
