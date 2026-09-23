import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class T2Terminal: Terminal {
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
@Suite(.serialized)
struct T2ParityTests {
    private func makeSession() -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model)))
        let manager = SessionManager.inMemory()
        let settings = SettingsManager.inMemory()
        let registry = ModelRegistry(AuthStorage(":memory:"))
        let resources = DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings))
        return AgentSession(config: AgentSessionConfig(
            agent: agent, sessionManager: manager, settingsManager: settings,
            resourceLoader: resources, modelRegistry: registry
        ))
    }
    private actor LoadState {
        var started = false
        var cancelled = false
        func markStarted() { started = true }
        func markCancelled() { cancelled = true }
    }
    private func click() -> TuiMouseEvent {
        TuiMouseEvent(type: .click, button: .left, x: 0, y: 0, screenX: 0, screenY: 0, width: 80, height: 10)
    }

    @Test func summaryAndSkillRowsToggleOnClick() throws {
        let branch = BranchSummaryMessageComponent(message: BranchSummaryMessage(summary: "branch detail", timestamp: 0))
        let branchRegion = try #require(branch.children.compactMap { $0 as? MouseRegion }.last)
        #expect(branchRegion.handleMouse(click())?.handled == true)
        #expect(branch.render(width: 80).joined(separator: "\n").contains("branch detail"))

        let compaction = CompactionSummaryMessageComponent(message: CompactionSummaryMessage(summary: "compact detail", tokensBefore: 100, timestamp: 0))
        let compactionRegion = try #require(compaction.children.compactMap { $0 as? MouseRegion }.last)
        #expect(compactionRegion.handleMouse(click())?.handled == true)
        #expect(compaction.render(width: 80).joined(separator: "\n").contains("compact detail"))

        let skill = SkillInvocationMessageComponent(skillBlock: ParsedSkillBlock(name: "test", location: "/tmp/test", content: "skill detail"))
        let box = try #require(skill.children.compactMap { $0 as? Box }.first)
        let skillRegion = try #require(box.children.compactMap { $0 as? MouseRegion }.last)
        #expect(skillRegion.handleMouse(click())?.handled == true)
        #expect(skill.render(width: 80).joined(separator: "\n").contains("skill detail"))
    }

    @Test func shellDurationUsesSecondsMinutesAndHours() {
        #expect(formatShellDuration(1.25) == "1.2s")
        #expect(formatShellDuration(59.9) == "59.9s")
        #expect(formatShellDuration(60) == "1m 0s")
        #expect(formatShellDuration(3671) == "1h 1m 11s")
    }

    @Test func configuredSelectorSaveKeysChangeMatchingAndHint() {
        _ = KeybindingsManager.inMemory(config: ["app.models.save": [MiniTui.Key.ctrl("r")], "app.thinking.save": [MiniTui.Key.ctrl("t")]])
        defer { _ = KeybindingsManager.inMemory() }
        #expect(selectorKeyText("app.models.save") == MiniTui.Key.ctrl("r"))
        #expect(selectorKeyMatches("\u{12}", "app.models.save"))
        #expect(!selectorKeyMatches("\u{13}", "app.models.save"))
        #expect(selectorKeyText("app.thinking.save") == MiniTui.Key.ctrl("t"))
    }

    @Test func thinkingSelectorUsesConfiguredSaveBinding() {
        _ = KeybindingsManager.inMemory(config: ["app.thinking.save": [MiniTui.Key.ctrl("r")]])
        defer { _ = KeybindingsManager.inMemory() }
        var saved = 0
        let selector = ThinkingSelectorComponent(
            currentLevel: .high, availableLevels: [.off, .high],
            onSelect: { _ in }, onCancel: {}, onSelectAsDefault: { _ in saved += 1 }
        )
        #expect(selector.render(width: 80).joined(separator: "\n").contains("ctrl+r to set as default"))
        selector.handleInput("\u{13}")
        #expect(saved == 0)
        selector.handleInput("\u{12}")
        #expect(saved == 1)
    }

    @Test func progressiveSessionRowsKeepUserSelectedPath() {
        func session(_ path: String, modified: TimeInterval) -> SessionInfo {
            SessionInfo(path: path, id: path, cwd: "/tmp", name: nil,
                        created: Date(timeIntervalSince1970: modified),
                        modified: Date(timeIntervalSince1970: modified),
                        messageCount: 1, firstMessage: path, allMessagesText: path)
        }
        let list = SessionList(sessions: [session("one", modified: 1), session("two", modified: 2)], showCwd: false)
        var selected: String?
        list.onSelect = { selected = $0 }
        list.handleInput("\u{1B}[B")
        list.setSessions([session("newest", modified: 3), session("one", modified: 1), session("two", modified: 2)], showCwd: false)
        list.handleInput("\r")
        #expect(selected == "two")
        list.resetNavigation()
        list.setSessions([session("latest", modified: 4), session("newest", modified: 3)], showCwd: false)
        list.handleInput("\r")
        #expect(selected == "latest")
    }

    @Test func closingSessionSelectorCancelsTranscriptReads() async throws {
        let state = LoadState()
        let loader: SessionsLoader = { _ in
            await state.markStarted()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await state.markCancelled()
                throw error
            }
            return []
        }
        let selector = SessionSelectorComponent(
            currentSessionsLoader: loader,
            allSessionsLoader: loader,
            onSelect: { _ in }, onCancel: {}, onExit: {}, requestRender: {}
        )
        for _ in 0..<100 where !(await state.started) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await state.started)
        selector.closeSelector()
        for _ in 0..<100 where !(await state.cancelled) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await state.cancelled)
    }

    @Test func sessionSelectorShowsPartialRowsBeforeLoadCompletes() async throws {
        let partial = SessionInfo(path: "/tmp/partial", id: "partial", cwd: "/tmp", name: nil,
                                  created: Date(), modified: Date(), messageCount: 1,
                                  firstMessage: "partial result", allMessagesText: "partial result")
        let loader: SessionsLoader = { onPartial in
            onPartial(1, 2, [partial])
            try await Task.sleep(for: .seconds(10))
            return [partial]
        }
        let selector = SessionSelectorComponent(
            currentSessionsLoader: loader, allSessionsLoader: loader,
            onSelect: { _ in }, onCancel: {}, onExit: {}, requestRender: {}
        )
        for _ in 0..<100 {
            if selector.render(width: 80).joined(separator: "\n").contains("partial result") { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(selector.render(width: 80).joined(separator: "\n").contains("partial result"))
        selector.closeSelector()
    }

    @Test func emptyCustomFooterUsesNoFullscreenRows() {
        let composition = InteractiveComposition(
            transcriptChildren: [Text("chat", paddingX: 0, paddingY: 0)],
            pendingMessages: Container(), status: Container(), widgets: Container(),
            editorSpacer: Spacer(0), editor: Text("editor\nline 2\nline 3", paddingX: 0, paddingY: 0),
            footer: Container(), scrollbar: .hidden, scrollbarStyle: { $0 }
        )
        let frame = renderLayoutFrame(root: composition.fullscreenRoot, width: 40, height: 8, requestRender: {})
        let footer = frame.root.children[1].children.last
        #expect(footer?.rect.height == 0)
    }

    @Test func compactionAndRetryStatusUseOptedInEditorBorder() {
        let session = makeSession()
        defer { session.dispose() }
        let tui = TUI(terminal: T2Terminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: KeybindingsManager.inMemory(), embedWorkingStatus: true)
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.handleSessionEvent(.autoCompactionStart(reason: .threshold))
        #expect(editor.render(width: 80)[0].contains("Compacting"))
        mode.handleSessionEvent(.autoCompactionEnd(result: nil, aborted: true, willRetry: false))
        #expect(!editor.render(width: 80)[0].contains("Compacting"))
        mode.handleSessionEvent(.autoRetryStart(attempt: 1, maxAttempts: 2, delayMs: 1, errorMessage: "retry"))
        #expect(editor.render(width: 80)[0].contains("Retrying"))
        mode.handleSessionEvent(.autoRetryEnd(success: true, attempt: 1, finalError: nil))
        #expect(!editor.render(width: 80)[0].contains("Retrying"))
    }

    @Test func interactiveInitializerUsesInjectedTerminal() {
        let session = makeSession()
        defer { session.dispose() }
        let terminal = T2Terminal()
        let mode = InteractiveMode(session: session, version: "test", terminal: terminal)
        #expect(mode.terminalForNewTui === terminal)
    }

    @Test func postLoginCatalogResultDoesNotReplaceLaterModelSelection() {
        let session = makeSession()
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        let originalModel = session.agent.state.model
        #expect(mode.canApplyPostLoginSelection(session, previousModel: originalModel, revision: 0))
        mode.recordUserModelSelection()
        #expect(!mode.canApplyPostLoginSelection(session, previousModel: originalModel, revision: 0))
    }

    @Test func shortcutHelpDescribesSelectionCopy() {
        let session = makeSession()
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: "test")
        mode.handleHotkeysCommand()
        #expect(mode.chatContainer.render(width: 100).joined(separator: "\n").contains("Copy selection or last assistant message"))
    }
}
