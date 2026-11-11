import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PT1OverlayTerminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var supportsTerminalQueries = true
    var writes = ""
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {}
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
private final class PT1OverlayProbe: Component {
    var close: HookCustomClose?
    func render(width: Int) -> [String] { ["extension overlay"] }
}

@MainActor @Suite(.serialized)
struct PT1OverlayTests {
    private func latestStatus(_ terminal: PT1OverlayTerminal) -> ProgramStatus? {
        guard let payload = terminal.writes.components(separatedBy: "\u{1B}]7501;").last,
              payload != terminal.writes else { return nil }
        let body = payload.components(separatedBy: "\u{1B}\\")[0].components(separatedBy: "\u{7}")[0]
        let fields = Dictionary(body.split(separator: ":").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]).removingPercentEncoding ?? String(pair[1]))
        }, uniquingKeysWith: { _, new in new })
        guard let raw = fields["state"], let state = ProgramStatus.State(rawValue: raw) else { return nil }
        return ProgramStatus(state: state, kind: fields["kind"].flatMap(ProgramStatus.Kind.init(rawValue:)),
            message: fields["msg"].flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) })
    }

    private func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), Comment(rawValue: label))
    }

    // v1.5.2 PT1: interactive-mode-extension-dialogs.test.ts:219,263.
    @Test func eachOverlayKeepsItsBlockedSourceWhileHiddenAndClearsAtDone() async throws {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([], "/tmp", manager, registry)
        let settings = SettingsManager.inMemory()
        let session = AgentSession(config: AgentSessionConfig(agent: Agent(),
            sessionManager: manager, settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings)),
            hookRunner: runner, modelRegistry: registry))
        defer { session.dispose() }
        let terminal = PT1OverlayTerminal()
        let tui = TUI(terminal: terminal)
        tui.programStatusEnvironment = { "1" }
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        defer { mode.resetExtensionDialogs(); tui.stop() }
        await mode.initializeHooksAndCustomTools()
        tui.start()
        mode.programStatus.report()
        let ui = runner.getUIContext()
        let first = PT1OverlayProbe()
        let second = PT1OverlayProbe()
        let firstHandle = LockedState<(any HookOverlayHandle)?>(nil)
        let firstTask = Task { await ui.custom({ _, _, _, done in
            await MainActor.run { first.close = done }
            return await MainActor.run { first }
        }, options: HookCustomOptions(overlay: true,
            onHandle: { handle in firstHandle.withLock { $0 = handle } },
            blocked: HookBlockedStatus(kind: .question, message: "First question"))) }
        try await waitUntil("first overlay handle and close callback") {
            first.close != nil && firstHandle.withLock { $0 } != nil
        }
        #expect(latestStatus(terminal)?.message == "First question")
        firstHandle.withLock { $0 }?.setHidden(true)
        #expect(latestStatus(terminal)?.message == "First question")
        let secondTask = Task { await ui.custom({ _, _, _, done in
            await MainActor.run { second.close = done }
            return await MainActor.run { second }
        }, options: HookCustomOptions(overlay: true,
            blocked: HookBlockedStatus(kind: .permission, message: "Second question"))) }
        try await waitUntil("second overlay blocked status") {
            second.close != nil && latestStatus(terminal)?.message == "Second question"
        }
        #expect(latestStatus(terminal)?.message == "Second question")
        second.close?(nil)
        _ = await secondTask.value
        #expect(latestStatus(terminal)?.message == "First question")
        mode.resetExtensionDialogs()
        _ = await firstTask.value
        #expect(latestStatus(terminal)?.state == .idle)
    }
}
