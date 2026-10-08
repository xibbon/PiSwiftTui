import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class V110StatusTerminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var supportsTerminalQueries = true
    var writes = ""
    var input: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { input = onInput }
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) { writes += data }
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor
private struct V110StatusHost {
    let session: AgentSession
    let terminal: V110StatusTerminal
    let tui: TUI
    let mode: InteractiveMode
    init(forced: Bool = true, session suppliedSession: AgentSession? = nil) {
        initTheme("dark")
        session = suppliedSession ?? t3aSession()
        terminal = V110StatusTerminal()
        terminal.supportsTerminalQueries = forced
        tui = TUI(terminal: terminal)
        tui.programStatusEnvironment = { forced ? "1" : nil }
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        mode = InteractiveMode(session: session, tui: tui, editor: editor)
        tui.start()
        mode.programStatus.report()
    }
    func close() { tui.stop(); session.dispose() }
    var reports: [ProgramStatus] {
        terminal.writes.components(separatedBy: "\u{1B}]7501;").dropFirst().compactMap { fragment in
            let payload = fragment.components(separatedBy: "\u{1B}\\")[0].components(separatedBy: "\u{7}")[0]
            let object = Dictionary(payload.split(separator: ":").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]).removingPercentEncoding ?? String(parts[1]))
            }, uniquingKeysWith: { _, new in new })
            guard let raw = object["state"], let state = ProgramStatus.State(rawValue: raw) else { return nil }
            return ProgramStatus(state: state, app: object["app"], kind: object["kind"].flatMap(ProgramStatus.Kind.init(rawValue:)), message: object["msg"].flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) })
        }
    }
}

@MainActor @Suite(.serialized) struct V110InteractiveStatusTests {
    @Test func agentEventsAndNameChangesReachTerminal() {
        let host = V110StatusHost(); defer { host.close() }
        host.mode.handleSessionEvent(.agent(.agentStart))
        #expect(host.reports.last?.state == .working)
        host.session.sessionManager.appendSessionInfo("Changed")
        host.mode.updateTerminalTitle()
        #expect(host.reports.last?.message == "Changed")
        host.mode.handleSessionEvent(.agent(.messageEnd(message: .assistant(t3aAssistant()))))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(host.reports.last?.state == .done)
        #expect(host.reports.last?.message == "Changed")
    }
    @Test func newSessionReturnsToIdle() {
        let host = V110StatusHost(); defer { host.close() }
        host.mode.handleSessionEvent(.agent(.agentStart))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        host.mode.handleNewSessionCommand()
        #expect(host.reports.last?.state == .idle)
    }
    @Test func resumeSessionReturnsToIdle() async throws {
        let host = V110StatusHost(); defer { host.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = SessionManager.create("/tmp", directory.path)
        target.appendMessage(.assistant(t3aAssistant()))
        let path = try #require(target.getSessionFile())
        host.mode.handleSessionEvent(.agent(.agentStart))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        await host.mode.handleResumeSession(path)
        #expect(host.reports.last?.state == .idle)
        #expect(host.session.sessionManager.getSessionFile() == path)
    }
    @Test func apiKeyLoginReportsAuthAndClearsAfterCancel() async throws {
        let host = V110StatusHost(); defer { host.close() }
        let login = Task { await host.mode.handleLoginCommand("groq") }
        let deadline = ContinuousClock.now + .seconds(2)
        while host.reports.last?.kind != .auth && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.reports.last?.state == .blocked)
        #expect(host.reports.last?.kind == .auth)
        host.mode.editorContainer?.children.first?.handleInput("\u{1B}")
        await login.value
        #expect(host.reports.last?.state == .idle)
    }
    @Test func hookConfirmReportsPermissionAndClears() async throws {
        let host = V110StatusHost(); defer { host.close() }
        let prompt = Task { await host.mode.showHookConfirm("Allow bash?", "Private command") }
        let deadline = ContinuousClock.now + .seconds(2)
        while host.reports.last?.kind != .permission && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.reports.last?.kind == .permission)
        #expect(host.reports.last?.message == "Allow bash?")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(await prompt.value)
        #expect(host.reports.last?.state == .idle)
        #expect(!host.reports.contains { $0.message?.contains("Private command") == true })
    }
    @Test func hookInputCancellationClearsBlockedState() async throws {
        let host = V110StatusHost(); defer { host.close() }
        let prompt = Task { await host.mode.showHookInput("Question", "Private placeholder") }
        let deadline = ContinuousClock.now + .seconds(2)
        while host.reports.last?.state != .blocked && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.reports.last?.kind == .question)
        prompt.cancel()
        #expect(await prompt.value == nil)
        #expect(host.reports.last?.state == .idle)
    }
    @Test func manualCompactionReportsWorkingThenError() async throws {
        let host = V110StatusHost(); defer { host.close() }
        host.mode.handleCompactCommand(nil)
        #expect(host.reports.last?.state == .working)
        #expect(host.reports.last?.message == "Compacting context")
        let deadline = ContinuousClock.now + .seconds(2)
        while host.reports.last?.state == .working && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.reports.last?.state == .error)
        #expect(host.reports.last?.message == "Compaction failed: Nothing to compact (session too small)")
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(host.reports.last?.state == .error)
        host.mode.handleSessionEvent(.agent(.agentStart))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(host.reports.last?.state == .done)
    }
    @Test func manualCompactionReportsWorkingThenDone() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = loginTestRegistry()
        let api = HookAPI()
        api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
            SessionBeforeCompactResult(compaction: CompactionResult(summary: "Private summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore))
        }
        let runner = HookRunner([LoadedHook(path: "status-test", resolvedPath: "status-test", handlers: api.handlers)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(keepRecentTokens: 100)
        session.settingsManager.applyOverrides(settings)
        manager.appendMessage(.user(UserMessage(content: .text("Older request"))))
        manager.appendMessage(.assistant(t3aAssistant()))
        manager.appendMessage(.user(UserMessage(content: .text(String(repeating: "x", count: 5000)))))
        var answer = t3aAssistant()
        answer.content = [.text(TextContent(text: String(repeating: "y", count: 500)))]
        manager.appendMessage(.assistant(answer))
        session.refreshContext()
        _ = try #require(prepareCompaction(manager.getBranch(), session.settingsManager.getCompactionSettings(model: session.agent.state.model)))
        let host = V110StatusHost(session: session); defer { host.close() }
        host.mode.handleSessionEvent(.agent(.agentStart))
        var failed = t3aAssistant()
        failed.stopReason = .error
        failed.errorMessage = "Previous run error"
        host.mode.handleSessionEvent(.agent(.messageEnd(message: .assistant(failed))))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(host.reports.last?.state == .error)
        host.mode.handleCompactCommand(nil)
        #expect(host.reports.last?.state == .working)
        let deadline = ContinuousClock.now + .seconds(2)
        while host.reports.last?.state == .working && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(host.reports.last?.state == .done)
        host.mode.handleSessionEvent(.agentSettled(aborted: true))
        #expect(host.reports.last?.state == .done)
        #expect(!host.reports.contains { $0.message?.contains("Private summary") == true })
    }
    @Test func defaultTerminalDoesNotReceive7501() {
        let host = V110StatusHost(forced: false); defer { host.close() }
        host.mode.handleSessionEvent(.agent(.agentStart))
        host.mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(!host.terminal.writes.contains("7501"))
    }
    @Test func transcriptRebuildClearsSelection() async {
        let host = V110StatusHost(); defer { host.close() }
        let renderer = host.tui.enableAltScreen(options: AltScreenRendererOptions(copyOnSelect: false, copySelection: { _ in true }))
        renderer.setLayoutRoot(ScrollView(Text("alpha\nbeta", paddingX: 0, paddingY: 0), options: ScrollViewOptions(follow: .end, primary: true)))
        _ = host.tui.switchRenderer(to: .altScreen)
        await host.tui.waitForRender()
        host.terminal.input?("\u{1B}[<0;1;1M")
        host.terminal.input?("\u{1B}[<32;4;2M")
        host.terminal.input?("\u{1B}[<0;4;2m")
        await Task.yield(); await host.tui.waitForRender()
        await Task.yield(); await host.tui.waitForRender()
        #expect(renderer.hasActiveSelection())
        let editor = CustomEditor(ui: host.tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: host.session, tui: host.tui, editor: editor, renderer: renderer)
        mode.renderInitialMessages()
        #expect(!renderer.hasActiveSelection())
    }
}
