import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private actor ShareGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
}

private final class ShareTerminal: Terminal {
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

@MainActor @Suite struct SessionShareV085Tests {
    @Test func concurrentGistExportsUseSeparateTemporaryDirectories() async throws {
        let aWritten = ShareGate(), bWritten = ShareGate(), releaseB = ShareGate()
        let uploads = LockedState<[(path: String, content: String)]>([])
        let errors = LockedState<[String]>([])
        let statuses = LockedState<[String]>([])
        let runner: @Sendable ([String], CancellationToken) async throws -> ExecResult = { arguments, _ in
            guard arguments.first == "gist" else { return ExecResult(stdout: "", stderr: "", code: 0, killed: false) }
            #expect(arguments.prefix(3) == ["gist", "create", "--public=false"])
            let path = try #require(arguments.last)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            uploads.withLock { $0.append((path, content)) }
            return ExecResult(stdout: "https://gist.github.com/test/123\n", stderr: "", code: 0, killed: false)
        }
        let dependenciesA = SessionShareDependencies(runGH: runner, exportHTML: { _, path, name in
            #expect(!name.isEmpty)
            try "A".write(toFile: path, atomically: true, encoding: .utf8)
            await aWritten.open()
            await bWritten.wait()
        })
        let dependenciesB = SessionShareDependencies(runGH: runner, exportHTML: { _, path, _ in
            try "B".write(toFile: path, atomically: true, encoding: .utf8)
            await bWritten.open()
            await releaseB.wait()
        })
        let shareA = Task { await runShare(dependenciesA, errors: errors, statuses: statuses) }
        await aWritten.wait()
        let shareB = Task { await runShare(dependenciesB, errors: errors, statuses: statuses) }
        await bWritten.wait()
        await shareA.value
        await releaseB.open()
        await shareB.value
        let captured = uploads.withLock { $0 }
        #expect(captured.map(\.content) == ["A", "B"])
        #expect(captured.count == 2)
        #expect(captured[0].path != captured[1].path)
        #expect(captured.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(statuses.withLock { $0 }.allSatisfy { $0.contains("#123") && $0.contains("Gist:") })
    }

    @Test func authenticationFailureDoesNotExportOrUpload() async {
        let calls = LockedState<[[String]]>([])
        let errors = LockedState<[String]>([])
        let dependencies = SessionShareDependencies(runGH: { arguments, _ in
            calls.withLock { $0.append(arguments) }
            return ExecResult(stdout: "", stderr: "not signed in", code: 1, killed: false)
        }, exportHTML: { _, _, _ in Issue.record("An unauthenticated share must not export") })
        await runShare(dependencies, errors: errors, statuses: LockedState([]))
        #expect(calls.withLock { $0 } == [["auth", "status"]])
        #expect(errors.withLock { $0 } == ["GitHub CLI is not logged in. Run 'gh auth login' first."])
    }

    private func runShare(_ dependencies: SessionShareDependencies, errors: LockedState<[String]>, statuses: LockedState<[String]>) async {
        let settings = SettingsManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let session = AgentSession(config: AgentSessionConfig(
            agent: Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: []))),
            sessionManager: SessionManager.inMemory(), settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: settings)),
            modelRegistry: ModelRegistry(AuthStorage(":memory:"))
        ))
        defer { session.dispose() }
        let ui = TUI(terminal: ShareTerminal())
        let editor = CustomEditor(ui: ui, theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        let container = Container()
        container.addChild(editor)
        await shareSession(session: session, tui: ui, editorContainer: container, editor: editor,
                           showStatus: { value in statuses.withLock { $0.append(value) } },
                           showError: { value in errors.withLock { $0.append(value) } }, dependencies: dependencies)
        #expect(container.children.count == 1)
        #expect(container.children.first === editor)
    }
}
