import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class HookEventResourceLoader: ResourceLoader {
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

private final class HookEventTerminal: Terminal {
    var columns = 80
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

@MainActor
private struct HookEventHost {
    let session: AgentSession
    let runner: HookRunner
    let tui: TUI
    let mode: InteractiveMode

    init(hooks: [LoadedHook] = [], streamFn: StreamFn? = nil) {
        let manager = SessionManager.inMemory("/tmp")
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("openai", "test")
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let model = Model(id: "hook-test", name: "Hook test", api: .openAIResponses,
                          provider: "openai", baseUrl: "https://example.invalid", reasoning: false,
                          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1000, maxTokens: 100)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model), streamFn: streamFn))
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 100, keepRecentTokens: 1)
        runner = HookRunner(hooks, "/tmp", manager, registry)
        session = AgentSession(config: AgentSessionConfig(
            agent: agent, sessionManager: manager, settingsManager: .inMemory(settings),
            resourceLoader: HookEventResourceLoader(), hookRunner: runner, modelRegistry: registry,
            reloadExtensionsHook: { LoadExtensionsResult(hooks: [], errors: []) }
        ))
        tui = TUI(terminal: HookEventTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        mode = InteractiveMode(session: session, tui: tui, editor: editor)
    }

    var transcript: String { mode.chatContainer.render(width: 160).joined(separator: "\n") }

    func dispose() {
        mode.unsubscribeFromAgent()
        session.dispose()
    }
}

@MainActor
@Suite struct HookEventConsumptionTests {
    @Test(arguments: [SessionCompactionReason.threshold, .overflow])
    func automaticFailureAddsPlainTranscriptError(_ reason: SessionCompactionReason) {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.handleHookEvent(SessionCompactFailedEvent(reason: reason, errorMessage: "Summary failed", aborted: false, willRetry: false, fromExtension: false))
        #expect(host.mode.chatContainer.children.count == 2)
        #expect(host.mode.chatContainer.children.first is Spacer)
        #expect(host.mode.chatContainer.children.last is Text)
        #expect(host.transcript.contains("Summary failed"))
        #expect(!host.transcript.contains("Error: Summary failed"))
    }

    @Test func automaticRetryUpdatesStatusOnce() {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.handleSessionEvent(.autoCompactionStart(reason: .overflow))
        host.mode.handleHookEvent(SessionCompactFailedEvent(reason: .overflow, errorMessage: "Summary failed", aborted: false, willRetry: true, fromExtension: false))
        host.mode.handleSessionEvent(.autoCompactionEnd(result: nil, aborted: false, willRetry: true))
        #expect(host.mode.chatContainer.children.count == 2)
        #expect(host.transcript.components(separatedBy: "Summary failed").count == 2)
        #expect(host.transcript.contains("Summary failed (retrying)"))
        #expect(!host.transcript.contains("Auto-compaction started"))
    }

    @Test func manualCommandFailureKeepsTheCommandErrorOnce() async throws {
        let host = HookEventHost(streamFn: { model, _, _ in
            let message = AssistantMessage(content: [.text(TextContent(text: "incomplete"))],
                api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                stopReason: .length)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .length, message: message))
            stream.end(message)
            return stream
        })
        defer { host.dispose() }
        host.session.sessionManager.appendMessage(.user(UserMessage(content: .text("one"))))
        host.session.sessionManager.appendMessage(.user(UserMessage(content: .text("two"))))
        host.session.agent.messages = host.session.sessionManager.buildSessionContext().messages
        host.mode.subscribeToAgent()
        host.mode.handleCompactCommand(nil)
        let deadline = ContinuousClock.now + .seconds(2)
        while !host.transcript.contains("token cap") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(host.transcript.components(separatedBy: "token cap").count == 2)
        #expect(host.transcript.components(separatedBy: "Error:").count == 2)
    }

    @Test func extensionManualFailureShowsOneError() {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.handleHookEvent(SessionCompactFailedEvent(reason: .manual, errorMessage: "Extension summary failed", aborted: false, willRetry: false, fromExtension: true))
        #expect(host.mode.chatContainer.children.count == 2)
        #expect(host.transcript.components(separatedBy: "Error: Extension summary failed").count == 2)
    }

    @Test(arguments: [SessionCompactionReason.manual, .threshold, .overflow])
    func abortedFailureAddsNoError(_ reason: SessionCompactionReason) {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.handleHookEvent(SessionCompactFailedEvent(reason: reason, errorMessage: "Cancelled", aborted: true, willRetry: false, fromExtension: true))
        #expect(host.mode.chatContainer.children.isEmpty)
        host.mode.handleSessionEvent(.autoCompactionEnd(result: nil, aborted: true, willRetry: false))
        #expect(host.transcript.components(separatedBy: "Auto-compaction cancelled").count == 2)
    }

    @Test func promptEventsAndFailureWithoutMessageAddNoOutput() {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.handleHookEvent(UIPromptStartEvent(kind: .confirm, title: "Continue?"))
        host.mode.handleHookEvent(UIPromptEndEvent(kind: .confirm, title: "Continue?"))
        host.mode.handleHookEvent(SessionCompactFailedEvent(reason: .threshold, aborted: false, willRetry: false, fromExtension: false))
        #expect(host.mode.chatContainer.children.isEmpty)
    }

    @Test func subscriptionReplacementAndCleanupDoNotDuplicateErrors() async throws {
        let host = HookEventHost()
        defer { host.dispose() }
        host.mode.subscribeToAgent()
        host.mode.subscribeToAgent()
        _ = await host.runner.emit(SessionCompactFailedEvent(reason: .threshold, errorMessage: "Observed failure", aborted: false, willRetry: false, fromExtension: false))
        let deadline = ContinuousClock.now + .seconds(2)
        while !host.transcript.contains("Observed failure") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(host.transcript.components(separatedBy: "Observed failure").count == 2)
        _ = await host.session.reloadExtensions()
        _ = await host.runner.emit(SessionCompactFailedEvent(reason: .threshold, errorMessage: "After reload", aborted: false, willRetry: false, fromExtension: false))
        let reloadDeadline = ContinuousClock.now + .seconds(2)
        while !host.transcript.contains("After reload") && ContinuousClock.now < reloadDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(host.transcript.components(separatedBy: "After reload").count == 2)
        host.mode.unsubscribeFromAgent()
        _ = await host.runner.emit(SessionCompactFailedEvent(reason: .threshold, errorMessage: "After cleanup", aborted: false, willRetry: false, fromExtension: false))
        await Task.yield()
        #expect(!host.transcript.contains("After cleanup"))
    }

    @Test func confirmThroughInteractiveContextEmitsPromptPair() async throws {
        let confirmed = Mutex<Bool?>(nil)
        let api = HookAPI()
        api.on("agent_start") { (_: AgentStartEvent, context: HookContext) in
            let result = await context.ui.confirm("Continue?", "Confirm this action")
            confirmed.withLock { $0 = result }
            return nil
        }
        let host = HookEventHost(hooks: [LoadedHook(path: "prompt-test", resolvedPath: "prompt-test", handlers: api.handlers)])
        defer { host.dispose() }
        let prompts = Mutex<[(String, UIPromptKind)]>([])
        let cancel = host.session.subscribeToHookEvents { event in
            if let event = event as? UIPromptStartEvent { prompts.withLock { $0.append((event.type, event.kind)) } }
            if let event = event as? UIPromptEndEvent { prompts.withLock { $0.append((event.type, event.kind)) } }
        }
        defer { cancel() }
        host.mode.subscribeToAgent()
        await host.mode.initializeHooksAndCustomTools()
        let initialTranscript = host.transcript
        let emission = Task { _ = await host.runner.emit(AgentStartEvent()) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(host.tui.getFocusedComponent() is HookSelectorComponent) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let selector = try #require(host.tui.getFocusedComponent() as? HookSelectorComponent)
        #expect(selector.render(width: 80).joined().contains("Confirm this action"))
        selector.handleInput("\r")
        await emission.value
        while prompts.withLock({ $0.count }) < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let events = prompts.withLock { $0 }
        #expect(confirmed.withLock { $0 } == true)
        #expect(events.map(\.0) == ["ui_prompt_start", "ui_prompt_end"])
        #expect(events.map(\.1) == [.confirm, .confirm])
        #expect(host.transcript == initialTranscript)
    }
}
