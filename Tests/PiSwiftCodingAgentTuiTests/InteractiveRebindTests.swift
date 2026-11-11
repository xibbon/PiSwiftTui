import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class RebindTerminal: Terminal {
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

enum ImportScenario: String, CaseIterable, Sendable {
    case existing
    case continueMissing
    case forkMissing
    case cancelConfirm
    case cancelDialog
    case veto
    case missingInput
    case failedBuild
}

private enum ImportFactoryFailure: Error { case requested }

@MainActor @Suite("Interactive session rebind", .serialized)
struct InteractiveRebindTests {
    private func waitForSelector(_ tui: TUI, after prior: HookSelectorComponent? = nil) async throws -> HookSelectorComponent {
        for _ in 0..<200 {
            if let selector = tui.getFocusedComponent() as? HookSelectorComponent,
               selector !== prior { return selector }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ImportFactoryFailure.requested
    }

    private func installReply(_ session: AgentSession, text: String) {
        session.agent.streamFn = { model, _, _ in
            var message = t3aAssistant(model)
            message.content = [.text(TextContent(text: text))]
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }
    }

    private func checkPromptReply(_ session: AgentSession, mode: InteractiveMode, text: String) async throws {
        mode.subscribeToAgent()
        let task = try await session.submitPrompt("still active")
        try await task.value
        for _ in 0..<200 {
            if mode.chatContainer.render(width: 100).joined().contains(text) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(mode.chatContainer.render(width: 100).joined().contains(text))
    }
    @Test func importPathAcceptsQuotesAndSpaces() {
        #expect(parseImportSessionPath("  '/tmp/my session.jsonl'  ") == "/tmp/my session.jsonl")
        #expect(parseImportSessionPath("\"/tmp/other session.jsonl\"") == "/tmp/other session.jsonl")
        #expect(parseImportSessionPath("john's/session.jsonl") == "john's/session.jsonl")
        #expect(parseImportSessionPath("/tmp/session.jsonl ignored") == "/tmp/session.jsonl")
        #expect(parseImportSessionPath("'/tmp/unclosed.jsonl") == nil)
        #expect(parseImportSessionPath("  ") == nil)
    }

    @Test func replacementFooterReadsTargetBranch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-footer-\(UUID())")
        let git = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "ref: refs/heads/rebound\n".write(to: git.appendingPathComponent("HEAD"),
            atomically: true, encoding: .utf8)
        let footerData = SessionFooterDataProvider(cwd: directory.path)
        #expect(footerData.getGitBranch() == "rebound")
    }

    @Test("/import keeps file and active session rules for every choice", arguments: ImportScenario.allCases)
    func importChoicesAndRollback(_ scenario: ImportScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-import-\(UUID())")
        let current = root.appendingPathComponent("current")
        let stored = root.appendingPathComponent("stored")
        let sessions = root.appendingPathComponent("sessions")
        let sources = root.appendingPathComponent("sources")
        for folder in [current, stored, sessions, sources] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let initialManager = SessionManager.create(current.path, sessions.path)
        let sourceCwd = scenario == .continueMissing || scenario == .forkMissing || scenario == .cancelDialog
            ? root.appendingPathComponent("gone").path : stored.path
        let source = SessionManager.create(sourceCwd, sources.path)
        source.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(source.getSessionFile())
        let original = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = scenario == .veto ? HookRunner([LoadedHook(path: "<import-veto>",
            resolvedPath: "<import-veto>",
            handlers: ["session_before_switch": [{ _, _ in SessionBeforeSwitchResult(cancel: true) }]],
            isExtension: true)], current.path, initialManager, registry) : nil
        let initial = t3aSession(manager: initialManager, registry: registry, runner: runner)
        installReply(initial, text: "old session replied")
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            if scenario == .failedBuild { throw ImportFactoryFailure.requested }
            return t3aSession(manager: args.sessionManager)
        }, initialSession: initial)
        defer { runtime.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: initial, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }
        let inputPath = scenario == .missingInput ? sources.appendingPathComponent("absent.jsonl").path : sourcePath
        let importing = Task { await mode.handleImportSession(inputPath) }
        let confirm = try await waitForSelector(tui)
        if scenario == .cancelConfirm { confirm.handleInput("\u{001B}[B") }
        confirm.handleInput("\r")
        if scenario == .continueMissing || scenario == .forkMissing || scenario == .cancelDialog {
            let choice = try await waitForSelector(tui, after: confirm)
            let index = scenario == .continueMissing ? 0 : scenario == .forkMissing ? 1 : 2
            for _ in 0..<index { choice.handleInput("\u{001B}[B") }
            choice.handleInput("\r")
        }
        await importing.value
        #expect(try Data(contentsOf: URL(fileURLWithPath: sourcePath)) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
            .filter { $0.hasSuffix(".jsonl") }
        let success = [.existing, .continueMissing, .forkMissing].contains(scenario)
        #expect((runtime.session === initial) == !success)
        #expect(files.count == (success ? 1 : 0))
        if success, let next = runtime.session {
            #expect(next.sessionManager.getSessionId() != initial.sessionManager.getSessionId())
            #expect(next.sessionManager.getCwd() == (scenario == .existing ? stored.path : current.path))
        } else {
            try await checkPromptReply(initial, mode: mode, text: "old session replied")
        }
    }

    @Test func extensionCallbackUsesReplacementSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-rebind-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstManager = SessionManager.create(directory.path, directory.path)
        let nextManager = SessionManager.create(directory.path, directory.path)
        nextManager.appendMessage(.user(UserMessage(content: .text("target"))))
        let path = try #require(nextManager.getSessionFile())
        let first = t3aSession(manager: firstManager)
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([], directory.path, nextManager, registry)
        let next = t3aSession(manager: nextManager, registry: registry, runner: runner)
        defer { first.dispose(); next.dispose() }
        let runtime = AgentSessionRuntime(agentDir: directory.path, factory: { _ in next }, initialSession: first)
        let mode = InteractiveMode(session: first, version: "test", runtime: runtime)
        let seen = LockedState<String?>(nil)
        let result = await mode.switchSessionFromHook(path,
            options: HookSwitchSessionOptions(withSession: { context in
                seen.withLock { $0 = context.sessionManager.getSessionFile() }
            }))
        #expect(!result.cancelled)
        #expect(seen.withLock { $0 } == path)
        #expect(runtime.session === next)
    }

    @Test func replacementSessionStartSeesBoundUIExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-start-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstManager = SessionManager.create(directory.path, directory.path)
        let nextManager = SessionManager.create(directory.path, directory.path)
        nextManager.appendMessage(.user(UserMessage(content: .text("target"))))
        let path = try #require(nextManager.getSessionFile())
        let first = t3aSession(manager: firstManager)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let count = LockedState(0)
        let hasUI = LockedState(false)
        let runner = HookRunner([LoadedHook(path: "<start-notify>", resolvedPath: "<start-notify>",
            handlers: ["session_start": [{ _, context in
                count.withLock { $0 += 1 }
                hasUI.withLock { $0 = context.hasUI }
                await context.ui.notify("replacement UI ready", .warning)
                return nil
            }]], isExtension: true)], directory.path, nextManager, registry)
        let next = t3aSession(manager: nextManager, registry: registry, runner: runner)
        let runtime = AgentSessionRuntime(agentDir: directory.path, factory: { _ in next }, initialSession: first)
        defer { runtime.dispose() }
        let priorTheme = theme.name
        initTheme("dark")
        defer { initTheme(priorTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: first, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }
        await mode.handleResumeSession(path)
        for _ in 0..<100 {
            if mode.chatContainer.render(width: 80).joined().contains("replacement UI ready") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(count.withLock { $0 } == 1)
        #expect(hasUI.withLock { $0 })
        #expect(mode.chatContainer.render(width: 80).joined().contains("replacement UI ready"))
    }

    @Test func missingCwdCancellationKeepsCurrentSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-missing-cwd-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = SessionManager.create(directory.path, directory.path)
        let missing = directory.appendingPathComponent("missing").path
        let target = SessionManager.create(missing, directory.path)
        target.appendMessage(.user(UserMessage(content: .text("target"))))
        let path = try #require(target.getSessionFile())
        let initial = t3aSession(manager: current)
        defer { initial.dispose() }
        let runtime = AgentSessionRuntime(agentDir: directory.path,
            factory: { args in t3aSession(manager: args.sessionManager) }, initialSession: initial)
        let previousTheme = theme.name
        defer { initTheme(previousTheme) }
        initTheme("dark")
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: initial, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }
        let switching = Task { await mode.handleResumeSession(path) }
        for _ in 0..<200 where !(tui.getFocusedComponent() is HookSelectorComponent) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let selector = try #require(tui.getFocusedComponent() as? HookSelectorComponent)
        selector.handleInput("\u{001B}")
        await switching.value
        #expect(runtime.session === initial)
    }

    @Test("continues the original session in the current cwd without writing a file")
    func missingCwdContinueKeepsSource() async throws {
        try await checkMissingCwdChoice(fork: false, veto: false)
    }

    @Test("forks the session into the current cwd and leaves the original unchanged")
    func missingCwdForkCreatesNewFile() async throws {
        try await checkMissingCwdChoice(fork: true, veto: false)
    }

    @Test("removes the fork when an extension cancels the switch")
    func missingCwdVetoRemovesFork() async throws {
        try await checkMissingCwdChoice(fork: true, veto: true)
    }

    @Test("extension switch missing cwd returns the chosen result and calls withSession only on success",
          arguments: [(0, false, false), (1, false, false), (2, false, false),
                      (1, true, false), (1, false, true)])
    func extensionSwitchMissingCwd(choiceIndex: Int, veto: Bool, failedBuild: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-extension-choice-\(UUID())")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialManager = SessionManager.create(current.path, sessions.path)
        let missingManager = SessionManager.create(root.appendingPathComponent("gone").path, sessions.path)
        missingManager.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(missingManager.getSessionFile())
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = veto ? HookRunner([LoadedHook(path: "<switch-veto>", resolvedPath: "<switch-veto>",
            handlers: ["session_before_switch": [{ _, _ in SessionBeforeSwitchResult(cancel: true) }]],
            isExtension: true)], current.path, initialManager, registry) : nil
        let initial = t3aSession(manager: initialManager, registry: registry, runner: runner)
        installReply(initial, text: "old extension session replied")
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { args in
            if failedBuild { throw ImportFactoryFailure.requested }
            let registry = ModelRegistry(AuthStorage.inMemory(), nil,
                modelsStore: InMemoryModelsStore(), networkEnabled: false)
            let runner = HookRunner([], args.cwd, args.sessionManager, registry)
            return t3aSession(manager: args.sessionManager, registry: registry, runner: runner)
        }, initialSession: initial)
        defer { runtime.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: initial, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }
        let withSession = LockedState<[String]>([])
        let switching = Task { await mode.switchSessionFromHook(sourcePath,
            options: HookSwitchSessionOptions(withSession: { context in
                withSession.withLock { $0.append(context.sessionManager.getCwd()) }
            })) }
        for _ in 0..<200 where !(tui.getFocusedComponent() is HookSelectorComponent) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let selector = try #require(tui.getFocusedComponent() as? HookSelectorComponent)
        for _ in 0..<choiceIndex { selector.handleInput("\u{001B}[B") }
        selector.handleInput("\r")
        let result = await switching.value
        let cancelled = choiceIndex == 2 || veto || failedBuild
        #expect(result.cancelled == cancelled)
        #expect(withSession.withLock { $0 } == (cancelled ? [] : [current.path]))
        #expect((runtime.session === initial) == cancelled)
        #expect(try Data(contentsOf: URL(fileURLWithPath: sourcePath)) == sourceBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
            .filter { $0.hasSuffix(".jsonl") }
        #expect(files.count == (!cancelled && choiceIndex == 1 ? 2 : 1))
        if cancelled {
            try await checkPromptReply(initial, mode: mode, text: "old extension session replied")
        }
    }

    private func checkMissingCwdChoice(fork: Bool, veto: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-choice-\(UUID())")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialManager = SessionManager.create(current.path, sessions.path)
        let missingManager = SessionManager.create(root.appendingPathComponent("gone").path, sessions.path)
        missingManager.appendMessage(.user(UserMessage(content: .text("source"))))
        let sourcePath = try #require(missingManager.getSessionFile())
        let original = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = veto ? HookRunner([LoadedHook(path: "<veto>", resolvedPath: "<veto>",
            handlers: ["session_before_switch": [{ _, _ in SessionBeforeSwitchResult(cancel: true) }]],
            isExtension: true)], current.path, initialManager, registry) : nil
        let initial = t3aSession(manager: initialManager, registry: registry, runner: runner)
        let runtime = AgentSessionRuntime(agentDir: root.path,
            factory: { args in t3aSession(manager: args.sessionManager) }, initialSession: initial)
        defer { runtime.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: initial, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }
        let switching = Task { await mode.handleResumeSession(sourcePath) }
        for _ in 0..<200 where !(tui.getFocusedComponent() is HookSelectorComponent) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let selector = try #require(tui.getFocusedComponent() as? HookSelectorComponent)
        if fork { selector.handleInput("\u{001B}[B") }
        selector.handleInput("\r")
        await switching.value
        #expect(try Data(contentsOf: URL(fileURLWithPath: sourcePath)) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
            .filter { $0.hasSuffix(".jsonl") }
        if veto {
            #expect(runtime.session === initial)
            #expect(files.count == 1)
        } else if let next = runtime.session {
            #expect(next.sessionManager.getCwd() == current.path)
            #expect((next.sessionManager.getSessionId() == missingManager.getSessionId()) == !fork)
            #expect(files.count == (fork ? 2 : 1))
        } else {
            Issue.record("Runtime lost the active session")
        }
    }

    @Test func mountedReplacementUsesNewStreamToolsReloadAndSessionState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-sweep-\(UUID())")
        let firstFolder = root.appendingPathComponent("first")
        let nextFolder = root.appendingPathComponent("next")
        for folder in [firstFolder, nextFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "new folder marker\n".write(to: nextFolder.appendingPathComponent("relative.txt"),
            atomically: true, encoding: .utf8)
        let initialManager = SessionManager.create(firstFolder.path, root.path)
        let targetManager = SessionManager.create(nextFolder.path, root.path)
        targetManager.appendMessage(.user(UserMessage(content: .text("target"))))
        let targetPath = try #require(targetManager.getSessionFile())
        let initial = makeSweepSession(manager: initialManager, streamCalls: LockedState(0))
        let streamCalls = LockedState(0)
        let next = makeSweepSession(manager: targetManager, streamCalls: streamCalls)
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { _ in next }, initialSession: initial)
        defer { runtime.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: initial, tui: tui, editor: editor, runtime: runtime)
        tui.start()
        defer { tui.stop() }

        await mode.handleResumeSession(targetPath)
        #expect(runtime.session === next)
        #expect(next.sessionManager.getCwd() == nextFolder.path)
        #expect(initial.cacheWarmer !== next.cacheWarmer)
        #expect(await next.cacheWarmingStatus() != nil)
        let task = try await next.submitPrompt("show stream marker")
        try await task.value
        for _ in 0..<200 {
            if mode.chatContainer.render(width: 120).joined().contains("new bundle stream marker") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(streamCalls.withLock { $0 } == 1)
        #expect(mode.chatContainer.render(width: 120).joined().contains("new bundle stream marker"))

        let beforeOldEvent = mode.chatContainer.render(width: 120).joined()
        initial.emitCacheWarmed(UsageEntry(id: UUID().uuidString, timestamp: "2026-01-01T00:00:00Z",
            kind: "cache_warm", provider: "test", model: "selected",
            usage: t3aUsage(), note: "old session event marker"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(mode.chatContainer.render(width: 120).joined() == beforeOldEvent)
        let read = try #require(next.agent.state.tools.first { $0.name == "read" })
        let result = try await read.execute("relative", ["path": AnyCodable("relative.txt")], nil, nil)
        #expect(result.content.contains { content in
            if case .text(let text) = content { return text.text.contains("new folder marker") }
            return false
        })

        await mode.handleReloadCommand()
        #expect(next.agent.state.tools.contains { $0.name == "read" })
        await mode.handleEditorSubmit("/compact")
        for _ in 0..<200 {
            if next.sessionManager.getEntries().contains(where: {
                if case .compaction = $0 { return true }
                return false
            }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.sessionManager.getEntries().contains {
            if case .compaction = $0 { return true }
            return false
        })
        #expect(streamCalls.withLock { $0 } > 1)
        await mode.handleEditorSubmit("/tree")
        let tree = try #require(tui.getFocusedComponent() as? TreeSelectorComponent)
        #expect(tree.render(width: 100).joined().contains("target"))
        tree.handleInput("\u{001B}")
        #expect(tui.getFocusedComponent() === editor)
        let beforeForkID = next.sessionManager.getSessionId()
        await mode.handleEditorSubmit("/fork")
        let forkSelector = try #require(tui.getFocusedComponent())
        #expect(forkSelector !== editor)
        forkSelector.handleInput("\r")
        for _ in 0..<200 where next.sessionManager.getSessionId() == beforeForkID {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.sessionManager.getSessionId() != beforeForkID)
        #expect(next.sessionManager.getCwd() == nextFolder.path)
        let oldID = next.sessionManager.getSessionId()
        mode.handleNewSessionCommand()
        for _ in 0..<200 where next.sessionManager.getSessionId() == oldID {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(next.sessionManager.getSessionId() != oldID)
        #expect(next.sessionManager.getCwd() == nextFolder.path)
        try await next.setModel(t3aModel("changed"))
        #expect(next.agent.state.model.id == "changed")

        next.sessionManager.appendMessage(.user(UserMessage(content: .text("before write failure"))))
        let currentPath = try #require(next.sessionManager.getSessionFile())
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: currentPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: currentPath) }
        next.sessionManager.appendMessage(.user(UserMessage(content: .text("write failure"))))
        #expect(next.sessionManager.getLastWriteError() != nil)
        mode.handleSessionEvent(.agentSettled(aborted: false))
        #expect(mode.chatContainer.render(width: 120).joined().contains("Session file could not be written"))
    }

    private func makeSweepSession(manager: SessionManager, streamCalls: LockedState<Int>) -> AgentSession {
        let model = t3aModel()
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        var settingValues = Settings()
        settingValues.compaction = CompactionSettingsOverrides(enabled: false,
            reserveTokens: 100, keepRecentTokens: 1)
        let settings = SettingsManager.inMemory(settingValues)
        let tools = createAllTools(cwd: manager.getCwd())
        let selected = [tools[.read], tools[.bash]].compactMap { $0 }
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: selected),
            streamFn: { model, _, _ in
                streamCalls.withLock { $0 += 1 }
                var message = t3aAssistant(model)
                message.content = [.text(TextContent(text: "new bundle stream marker"))]
                let stream = AssistantMessageEventStream()
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }))
        let warmer = CacheWarmer(stream: { model, _, _ in t3aAssistant(model) },
            sessionManager: manager, getMode: { .off })
        return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: manager.getCwd(),
                settingsManager: settings)), modelRegistry: registry, cacheWarmer: warmer,
            toolRegistry: Dictionary(uniqueKeysWithValues: selected.map { ($0.name, $0) }),
            toolRegistryOrder: selected.map(\.name)))
    }

    @Test func replacementClosesOldOverlayAndRunsNewMcpManager() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-mcp-rebind-\(UUID())")
        let oldFolder = root.appendingPathComponent("old")
        let newFolder = root.appendingPathComponent("new")
        for folder in [oldFolder, newFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let oldManager = SessionManager.create(oldFolder.path, root.path)
        let newManager = SessionManager.create(newFolder.path, root.path)
        newManager.appendMessage(.user(UserMessage(content: .text("new session"))))
        let newPath = try #require(newManager.getSessionFile())
        let oldRegistry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let oldRunner = HookRunner([], oldFolder.path, oldManager, oldRegistry)
        let old = t3aSession(manager: oldManager, registry: oldRegistry, runner: oldRunner)
        let newBridge = InteractiveMcpUi()
        let selected = LockedState<String?>(nil)
        let command = RegisteredCommand(name: "mcp",
            sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user")) { _, _ in
            let choice = await newBridge.menu(McpMenu(title: "Replacement MCP", items: [
                McpMenuItem(value: "new-server", label: "new-server")
            ], confirmLabel: "manage", cancelLabel: "close"))
            selected.withLock { $0 = choice }
        }
        let newRegistry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let newRunner = HookRunner([LoadedHook(path: "builtin:mcp", resolvedPath: "builtin:mcp",
            handlers: [:], commands: ["mcp": command])], newFolder.path, newManager, newRegistry)
        let next = t3aSession(manager: newManager, registry: newRegistry, runner: newRunner)
        let runtime = AgentSessionRuntime(agentDir: root.path, factory: { _ in next }, initialSession: old)
        defer { runtime.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let bindings = InteractiveSessionBindings(
            customToolsResult: CustomToolsLoadResult(tools: [], errors: []), mcpUi: newBridge)
        let mode = InteractiveMode(session: old, tui: tui, editor: editor, runtime: runtime,
            replacementBindings: { _ in bindings })
        tui.start()
        defer { tui.stop() }
        await mode.initializeHooksAndCustomTools(emitStartEvent: false)
        let oldUI = oldRunner.getUIContext()
        let overlay = Task { await oldUI.custom({ _, _, _, _ in await MainActor.run { Text("OLD OVERLAY") } },
            options: HookCustomOptions(overlay: true)) }
        for _ in 0..<200 where !tui.hasOverlay() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(tui.hasOverlay())
        await mode.handleResumeSession(newPath)
        #expect(await overlay.value == nil)
        #expect(!tui.hasOverlay())
        #expect(runtime.session === next)
        let mcp = Task { await mode.handleHookCommand("/mcp") }
        for _ in 0..<200 where !(tui.getFocusedComponent() is McpManagerView) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let manager = try #require(tui.getFocusedComponent() as? McpManagerView)
        #expect(manager.render(width: 120).joined().contains("new-server"))
        manager.handleInput("\r")
        #expect(await mcp.value)
        #expect(selected.withLock { $0 } == "new-server")
        #expect(tui.getFocusedComponent() === editor)
    }

    @Test func extensionShutdownWaitsForStreamingResponseAndRunsOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-shutdown-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SessionManager.create(folder.path, folder.path)
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let command = RegisteredCommand(name: "bye") { _, context in context.shutdown() }
        let runner = HookRunner([LoadedHook(path: "<shutdown-command>",
            resolvedPath: "<shutdown-command>", handlers: [:], commands: ["bye": command],
            isExtension: true)], folder.path, manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        let release = LockedState<CheckedContinuation<Void, Never>?>(nil)
        let count = LockedState(0)
        session.agent.streamFn = { model, _, _ in
            let stream = AssistantMessageEventStream()
            Task {
                await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
                var message = t3aAssistant(model)
                message.content = [.text(TextContent(text: "settled response marker"))]
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
            return stream
        }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor,
            shutdownSession: {
                count.withLock { $0 += 1 }
                session.dispose()
            }, exitProcess: { _ in })
        tui.start()
        defer { tui.stop() }
        await mode.initializeHooksAndCustomTools(emitStartEvent: false)
        runner.setShutdownHandler { [weak mode] in
            Task { @MainActor [weak mode] in mode?.requestShutdownFromHook() }
        }
        mode.subscribeToAgent()
        let prompt = try await session.submitPrompt("wait")
        for _ in 0..<200 where release.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.isStreaming)
        #expect(await mode.handleHookCommand("/bye"))
        #expect(count.withLock { $0 } == 0)
        release.withLock { $0?.resume(); $0 = nil }
        try await prompt.value
        for _ in 0..<200 where count.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(count.withLock { $0 } == 1)
    }

    @Test func idleExtensionCommandShutdownRunsOnceWithoutStreaming() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-idle-shutdown-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = SessionManager.create(folder.path, folder.path)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let command = RegisteredCommand(name: "bye") { _, context in context.shutdown() }
        let runner = HookRunner([LoadedHook(path: "<idle-shutdown-command>",
            resolvedPath: "<idle-shutdown-command>", handlers: [:], commands: ["bye": command],
            isExtension: true)], folder.path, manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        let streams = LockedState(0)
        session.agent.streamFn = { model, _, _ in
            streams.withLock { $0 += 1 }
            let message = t3aAssistant(model)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }
        let shutdowns = LockedState(0)
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor,
            shutdownSession: {
                shutdowns.withLock { $0 += 1 }
                session.dispose()
            }, exitProcess: { _ in })
        tui.start()
        defer { tui.stop() }
        await mode.initializeHooksAndCustomTools(emitStartEvent: false)
        runner.setShutdownHandler { [weak mode] in
            Task { @MainActor [weak mode] in mode?.requestShutdownFromHook() }
        }
        #expect(session.isIdle)
        #expect(await mode.handleHookCommand("/bye"))
        for _ in 0..<200 where shutdowns.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(shutdowns.withLock { $0 } == 1)
        #expect(streams.withLock { $0 } == 0)
        runner.createCommandContext().shutdown()
        try await Task.sleep(for: .milliseconds(20))
        #expect(shutdowns.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func replacementTrustChoiceUsesMountedEditorSlot(_ cancel: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tui-trust-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = t3aSession(manager: SessionManager.inMemory(folder.path))
        defer { session.dispose() }
        let previousTheme = theme.name
        initTheme("dark")
        defer { initTheme(previousTheme) }
        let tui = TUI(terminal: RebindTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        tui.start()
        defer { tui.stop() }
        let settings = SettingsManager.inMemory()
        let choosing = Task { await mode.selectReplacementProjectTrust(cwd: folder.path,
            settingsManager: settings) }
        var selector: ProjectTrustSelectorComponent?
        for _ in 0..<200 {
            selector = tui.getFocusedComponent() as? ProjectTrustSelectorComponent
            if selector != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let mounted = try #require(selector)
        #expect(tui.getFocusedComponent() === mounted)
        mounted.handleInput(cancel ? "\u{001B}" : "\r")
        let result = await choosing.value
        #expect(cancel ? result == nil : result?.trusted == true)
        #expect(tui.getFocusedComponent() === editor)
    }
}
