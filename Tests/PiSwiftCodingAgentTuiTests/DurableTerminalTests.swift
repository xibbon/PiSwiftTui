import ArgumentParser
import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
@testable import PiSwiftCodingAgentCLI
@testable import PiSwiftCodingAgentTui
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private final class TerminalBackendFailure: Error, Sendable, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class TerminalTestSource: DurableHostViewSource {
    private let view: Mutex<DurableView>
    init() {
        view = Mutex(.init(session: .init(id: "terminal", directory: "/tmp/terminal", cwd: "/tmp"),
            conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
            conversations: [.init(id: rootConversationID, label: "main")],
            models: [.init(provider: "fake", modelId: "test", name: "Test", contextWindow: 1000)]))
    }
    // v1.5.2 D11: The source supplies the host snapshot.
    func hostCurrent() -> DurableHostView { d11HostView(current()) }
    func current() -> DurableView { view.withLock { $0 } }
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription {
        DurableViewSubscription {}
    }
    // This deliberately does not notify the UI. Each input path must check the current view.
    func fail() { terminate(.failed(message: "First cause")) }
    func terminate(_ terminal: DurableSessionTerminal) {
        view.withLock { current in
            // v1.5.2 D11: This source has an empty transcript; do not read the legacy conversation.
            current = .init(session: current.session,
                conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
                conversations: current.conversations, models: current.models,
                terminal: terminal)
        }
    }
}

private final class TerminalTestController: DurableHostController {
    private let actions = Mutex<[String]>([])
    var count: Int { actions.withLock { $0.count } }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async { record("submit") }
    func compact(instructions: String?) async { record("compact") }
    func abort() async { record("abort") }
    func cycleThinking() async { record("thinking") }
    func setModel(_ model: ModelRef) async { record("model") }
    func toggleTasks() async { record("tasks") }
    func switchConversation(_ id: ConversationID) async { record("conversation") }
    private func record(_ value: String) { actions.withLock { $0.append(value) } }
}

private final class TerminalTestTerminal: Terminal {
    var columns = 120
    var rows = 30
    var kittyProtocolActive = false
    var input: ((String) -> Void)?
    var stopped = false
    var writes = ""
    let started = HarnessChatSignal()
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        input = onInput
        started.signal()
    }
    func stop() { input = nil; stopped = true }
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

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DurableTerminalTests {
    @Test(arguments: ["submit", "followUp", "abort", "thinking", "tasks", "compact", "model", "agents", "selectedModel", "selectedConversation", "queued"])
    func terminalViewSealsEveryCommandBeforeListenerDelivery(_ command: String) async throws {
        let source = TerminalTestSource()
        let controller = TerminalTestController()
        var exits = 0
        let session = DurableTuiSession(source: source, controller: controller,
            terminal: TerminalTestTerminal(), exit: { exits += 1 })
        defer { session.stop() }
        func submit(_ text: String) {
            session.tui.editor.handleInput(text)
            session.tui.editor.handleInput("\r")
        }
        var selector: ListSelector?
        if command == "selectedModel" || command == "selectedConversation" {
            submit(command == "selectedModel" ? "/model" : "/agents")
            selector = try #require(session.tui.editorContainer.children.first as? ListSelector)
        }
        if command == "queued" { submit("queued before failure") }
        source.fail()
        switch command {
        case "followUp":
            session.tui.editor.handleInput("follow up")
            session.tui.editor.handleInput("\u{001B}\r")
        case "abort": session.tui.editor.handleInput("\u{001B}")
        case "thinking": session.tui.editor.handleInput("\u{001B}[Z")
        case "tasks": submit("/tasks")
        case "compact": submit("/compact keep details")
        case "model": submit("/model")
        case "agents": submit("/agents")
        case "selectedModel", "selectedConversation": selector?.handleInput("\r")
        default: submit("rejected input")
        }
        await Task.yield()
        #expect(controller.count == 0)
        // v1.5.2 D11: Failure seals writes and leaves the recovery prompt open.
        #expect(exits == 0)
        session.apply(source.hostCurrent())
        session.terminalClosed()
        #expect(exits == 0)
        session.tui.editor.setText("")
        session.tui.editor.handleInput("\u{0004}")
        #expect(exits == 1)
    }

    @Test(arguments: [false, true])
    func closedObserverStopsWithoutViewNotification(_ failed: Bool) async throws {
        let source = TerminalTestSource()
        let terminal = TerminalTestTerminal()
        let closed = HarnessChatSignal()
        let run = Task {
            await runDurableTui(view: source, controller: TerminalTestController(),
                settings: SettingsManager.inMemory(), terminal: terminal, closed: {
                    await closed.wait()
                    return failed ? .failed(TerminalBackendFailure("First cause")) : .closed
                })
        }
        await terminal.started.wait()
        source.terminate(failed ? .failed(message: "First cause") : .closed)
        closed.signal()
        if failed {
            // v1.5.2 D11: Storage failure stays visible until the user quits.
            for _ in 0..<200 where !terminal.writes.contains("/reopen or Ctrl-D to quit") {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(terminal.writes.contains("/reopen or Ctrl-D to quit"))
            #expect(!terminal.stopped)
            terminal.input?("\u{0004}")
        }
        await run.value
        #expect(terminal.stopped)
        if failed { #expect(terminal.writes.contains("First cause")) }
        else { #expect(terminal.writes.contains("Session closed")) }
    }

    @Test func actualBackendFailureWaitsForQuitAndOneCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tui-terminal-" + UUID().uuidString)
        let cwd = directory.appendingPathComponent("cwd")
        let agent = directory.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"retry\":{\"enabled\":false},\"compaction\":{\"enabled\":false}}".utf8)
            .write(to: agent.appendingPathComponent("settings.json"))
        let original = TerminalBackendFailure("First backend cause")
        let storage = TerminalFailureStorage(closeFailure: TerminalBackendFailure("Later close cause"))
        let model = HarnessGatedResponse(message: chatAssistant("answer"))
        let models = FakeDurableModels(responses: [model.step])
        let cleanupReached = HarnessChatSignal(), cleanupRelease = HarnessChatSignal()
        let cleanupCount = Mutex(0)
        let envs = ExecutionEnvs(defaultCwd: cwd.resolvingSymlinksInPath().path, cleanup: { env, context in
            cleanupCount.withLock { $0 += 1 }
            cleanupReached.signal()
            await cleanupRelease.wait()
            await env.cleanup(context: context)
        })
        let durable = try await openDurable(.init(cwd: cwd.path), dependencies:
            .init(agentDirectory: agent.path, makeModels: { _ in
                .init(models: models, available: models.models, initial: { _ in
                    .init(model: .init(provider: "faux", modelId: "faux-1"))
                })
            }, makeStorage: { _ in storage }, makeEnvs: { _ in envs }))
        let terminal = TerminalTestTerminal()
        let finished = Mutex(false)
        let run = Task {
            let result = await runDurableTui(durable, terminal: terminal)
            finished.withLock { $0 = true }
            return result
        }
        await terminal.started.wait()
        terminal.input?("start")
        terminal.input?("\r")
        do {
            try await eventually { model.reached.isSignalled }
            storage.failNextCommit(original)
            model.release()
            try await eventually { cleanupReached.isSignalled }
        } catch {
            model.release()
            cleanupRelease.signal()
            run.cancel()
            _ = await run.value
            throw error
        }
        #expect(durable.hostView.hostCurrent().terminal == .failed(message: original.message))
        #expect(!finished.withLock { $0 })
        let commits = storage.commitCount
        terminal.input?("must not run")
        terminal.input?("\r")
        terminal.input?("\u{001B}")
        terminal.input?("\u{001B}[Z")
        #expect(storage.commitCount == commits)
        cleanupRelease.signal()
        // v1.5.2 D11: Cleanup finishes while the failed interface awaits quit.
        for _ in 0..<200 where !terminal.writes.contains("/reopen or Ctrl-D to quit") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.writes.contains("/reopen or Ctrl-D to quit"))
        #expect(!finished.withLock { $0 })
        terminal.input?("\u{0004}")
        let result = await run.value
        guard case .failed(let cause) = result else { Issue.record("Expected failed session"); return }
        #expect((cause as? TerminalBackendFailure) === original)
        #expect(terminal.stopped)
        #expect(terminal.writes.contains(original.message))
        #expect(!terminal.writes.contains("Later close cause"))
        #expect(cleanupCount.withLock { $0 } == 1)
        #expect(storage.closeCount == 1)
        var reports: [String] = []
        #expect(throws: ExitCode.failure) {
            try DurableSubcommand.checkTerminalResult(result, report: { reports.append($0) })
        }
        #expect(reports == [original.message])
        await durable.close()
        #expect(cleanupCount.withLock { $0 } == 1)
        #expect(storage.closeCount == 1)
        let reopened = try await selectSession(cwd.path, continueSession: true, agentDirectory: agent.path)
        reopened.release()
    }
}

final class TerminalFailureStorage: DurableStorage {
    private struct State: Sendable {
        var nextFailure: (any Error)?
        var commits = 0
        var closes = 0
    }
    let base: any DurableStorage
    let closeFailure: (any Error)?
    private let state = Mutex(State())
    init(base: any DurableStorage = MemoryStorage(), closeFailure: (any Error)? = nil) {
        self.base = base
        self.closeFailure = closeFailure
    }
    var commitCount: Int { state.withLock { $0.commits } }
    var closeCount: Int { state.withLock { $0.closes } }
    func failNextCommit(_ error: any Error) { state.withLock { $0.nextFailure = error } }
    // v1.5.2 D11: Exercise the batch commit surface so the D2 bridge can be removed.
    func commit(_ batches: [[StorageWrite]], receive: @Sendable (Int, Seq) -> Void,
                context: ChordContext) async throws -> CommitResult {
        let failure = state.withLock { state in
            state.commits += 1
            let failure = state.nextFailure
            state.nextFailure = nil
            return failure
        }
        if let failure { throw failure }
        return try await base.commit(batches, receive: receive, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await base.conversation(id, context: context)
    }

    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }

    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(id, context: context)
    }

    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(conversationId, id: id, context: context)
    }

    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }

    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }

    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await base.task(id, context: context)
    }

    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submission(id, context: context)
    }

    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }

    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }

    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await base.findDocument(address, at: at, context: context)
    }

    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await base.document(id, at: at, context: context)
    }

    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }

    func close(context: ChordContext) async throws {
        state.withLock { $0.closes += 1 }
        try await base.close(context: context)
        if let closeFailure { throw closeFailure }
    }
}
