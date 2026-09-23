import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class BugFlowTerminal: Terminal {
    var columns = 100
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

private final class BugCrashResourceLoader: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: ["/tmp/pi-extension.dylib"], diagnostics: []) }
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
private func waitForBugComponent<T: Component>(_ type: T.Type, in container: Container) async throws -> T {
    for _ in 0..<100 {
        if let component = container.children.first as? T { return component }
        await Task.yield()
    }
    throw BugReportFlowError.summaryFailed("Bug report dialog did not appear")
}

@MainActor
@Suite struct BugReportFlowTests {
    @Test func summaryConversationKeepsRecentMessagesWithinBudget() {
        let messages: [AgentMessage] = [
            .user(UserMessage(content: .text(String(repeating: "old ", count: 100)))),
            .user(UserMessage(content: .text("recent failure")))
        ]
        let conversation = bugReportSummaryConversation(messages, contextWindow: 100)
        #expect(conversation.contains("recent failure"))
        #expect(!conversation.contains("old old"))
        #expect(conversation.contains("Only the last 1 of 2 messages"))
    }

    @Test func localZipKeepsMultilineDescriptionAndShareEntry() async throws {
        initTheme("dark")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-bug-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        _ = manager.appendMessage(.user(UserMessage(content: .text("The command failed"))))
        let settings = SettingsManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test prompt", model: model, tools: []))),
            sessionManager: manager, settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path, settingsManager: settings)),
            modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        ))
        defer { session.dispose() }
        let tui = TUI(terminal: BugFlowTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let container = Container()
        container.addChild(editor)
        var statuses: [String] = []
        var errors: [String] = []
        let flow = BugReportUI(session: session, tui: tui, editorContainer: container, editor: editor,
                               showStatus: { statuses.append($0) }, showError: { errors.append($0) },
                               exportDirectory: directory.path, crashLog: CrashLog(path: directory.appendingPathComponent("crashes.json").path))
        let task = Task { await flow.run(initialHint: "first line\nsecond line") }
        let description = try await waitForBugComponent(HookEditorComponent.self, in: container)
        #expect(description.render(width: 100).joined(separator: "\n").contains("first line"))
        description.handleInput("\u{001B}[13;5u")
        let consent = try await waitForBugComponent(HookSelectorComponent.self, in: container)
        #expect(consent.render(width: 100).joined(separator: "\n").contains("The transcript contains"))
        consent.handleInput("\r")
        let delivery = try await waitForBugComponent(HookSelectorComponent.self, in: container)
        delivery.handleInput("\r")
        await task.value
        #expect(errors.isEmpty)
        #expect(statuses.last?.contains("Bug report exported to:") == true)
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }
        #expect(archives.count == 1)
        let archive = try String(decoding: Data(contentsOf: #require(archives.first)), as: UTF8.self)
        #expect(archive.contains("first line\\nsecond line"))
        #expect(archive.contains("session.jsonl"))
        #expect(archive.contains("pi.share"))
        #expect(manager.getEntries().contains { entry in
            if case .custom(let custom) = entry { return custom.customType == BUG_REPORT_CUSTOM_ENTRY_TYPE }
            return false
        })
        #expect(container.children.first === editor)
    }

    @Test func crashNoticeIsShownOnceWithExtensionAttribution() throws {
        initTheme("dark")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-crash-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = CrashLog(path: directory.appendingPathComponent("crashes.json").path)
        struct TestCrash: Error {}
        log.append(kind: .uncaughtException, error: TestCrash(), stack: "stack\nframe /tmp/pi-extension.dylib symbol", cwd: directory.path, version: "test")
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: SessionManager.inMemory(directory.path),
            settingsManager: .inMemory(), resourceLoader: BugCrashResourceLoader(),
            modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        ))
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        mode.crashLog = log
        mode.announceSavedCrashIfNeeded()
        let first = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(first.contains("Pi crashed during the previous session"))
        #expect(first.contains("pi-extension.dylib"))
        let count = mode.chatContainer.children.count
        mode.announceSavedCrashIfNeeded()
        #expect(mode.chatContainer.children.count == count)
    }
}
