import MiniTui
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class T2DurableSource: DurableHostViewSource {
    private let view: Mutex<DurableView>
    init(_ view: DurableView) { self.view = Mutex(view) }
    // v1.5.2 D11: The source supplies the host snapshot.
    func hostCurrent() -> DurableHostView { d11HostView(current()) }
    func current() -> DurableView { view.withLock { $0 } }
    func set(_ value: DurableView) { view.withLock { $0 = value } }
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription {
        DurableViewSubscription {}
    }
}

private actor T2DurableController: DurableHostController {
    enum Action: Sendable, Equatable {
        case continueRun, abortTask(TaskID), abort, submit(String)
    }
    nonisolated let events: AsyncStream<Action>
    private let output: AsyncStream<Action>.Continuation
    private(set) var actions: [Action] = []
    init() { (events, output) = AsyncStream.makeStream() }
    private func record(_ action: Action) { actions.append(action); output.yield(action) }
    func continueRun() { record(.continueRun) }
    func abortTask(_ id: TaskID) { record(.abortTask(id)) }
    func abort() { record(.abort) }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) { record(.submit(text)) }
    func compact(instructions: String?) {}
    func cycleThinking() {}
    func setModel(_ model: ModelRef) {}
    func toggleTasks() {}
    func switchConversation(_ id: ConversationID) {}
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct T2DurableControlTests {
    // v1.5.2 D11: Command fixtures use ordinary blocked tasks, not ended restart-limit work.
    private func view(blocked count: Int = 1, terminal: DurableSessionTerminal? = nil,
                      ending: RunFailureReason? = nil) throws -> DurableView {
        let blocked = try (0..<count).map {
            DurableBlockedTask(id: try TaskID(Int64(7 + $0)), kind: "pi.tool", reason: .missingTask)
        }
        var docs: [String: JSONObject] = [:]
        if let ending {
            let failure = RunFailure(taskId: try TaskID(2), inputs: [], reason: ending)
            docs["pi.live"] = ["runFailure": .object(try #require(JSONValue(encoding: failure).objectValue))]
        }
        return DurableView(session: .init(id: "controls", directory: "/tmp/controls", cwd: "/tmp"),
            conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: docs),
            conversations: [], models: [], terminal: terminal, blockedTasks: blocked,
            activity: count == 0 ? .idle : .blocked)
    }

    private func type(_ text: String, into session: DurableTuiSession) {
        session.tui.editor.handleInput(text)
        session.tui.editor.handleInput("\r")
    }

    // v1.5.2 D11: /continue replaces restart-limit retry commands.
    @Test func continueStartsWorkWithoutInput() async throws {
        let source = T2DurableSource(try view(blocked: 0))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("/continue", into: session)
        #expect(await events.next() == .continueRun)
        #expect(session.tui.editor.getText().isEmpty)
        session.tui.editor.handleInput("\u{001B}")
        #expect(await events.next() == .abort)
    }

    // v1.5.2 D11: The host's final ending offers continuation without new input.
    @Test(arguments: [RunFailureReason.turnLimit, .modelError])
    func continueAfterSavedEnding(_ reason: RunFailureReason) async throws {
        let source = T2DurableSource(try view(blocked: 0, ending: reason))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        session.apply(source.hostCurrent())
        #expect(toolTestText(session.tui.notices).contains(source.hostCurrent().ending!.text))
        var events = controller.events.makeAsyncIterator()
        type("/continue", into: session)
        #expect(await events.next() == .continueRun)
    }

    // v1.5.2 D11: Task abort uses an explicit task ID.
    @Test func abortCommandUsesExplicitTaskId() async throws {
        let source = T2DurableSource(try view(blocked: 0))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("/abort 42", into: session)
        #expect(await events.next() == .abortTask(try TaskID(42)))
    }

    @Test(arguments: ["/continuing", "/aborting"])
    func commandPrefixesRemainNormalInput(_ text: String) async throws {
        let source = T2DurableSource(try view())
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type(text, into: session)
        #expect(await events.next() == .submit(text))
    }

    @Test(arguments: ["/continue", "/abort 7"])
    func terminalViewSealsTaskCommandsBeforeListenerDelivery(_ command: String) async throws {
        let source = T2DurableSource(try view())
        let controller = T2DurableController()
        var exits = 0
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: { exits += 1 })
        defer { session.stop() }
        source.set(try view(terminal: .failed(message: "Storage failed")))
        type(command, into: session)
        await Task.yield()
        #expect(await controller.actions.isEmpty)
        // v1.5.2 D11: Failed storage blocks commands but permits explicit quit.
        #expect(exits == 0)
        #expect(toolTestText(session.tui.notices).contains("Session failed: Storage failed"))
        session.tui.editor.handleInput("\u{0004}")
        #expect(exits == 1)
    }

    // v1.5.2 D11: Failure offers reopen without dispatching a write command.
    @Test func failedSessionOffersReopenAndBlocksWritingCommands() async throws {
        let source = T2DurableSource(try view(terminal: .failed(message: "Storage failed")))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        session.apply(source.hostCurrent())
        #expect(toolTestText(session.tui.notices).contains("/reopen or Ctrl-D to quit"))
        type("must not write", into: session)
        type("/continue", into: session)
        type("/abort 7", into: session)
        await Task.yield()
        #expect(await controller.actions.isEmpty)
        session.tui.editor.handleInput("\u{0004}")
    }

    @Test(arguments: ["/continue", "/abort 7"])
    func terminalViewSealsAlreadyQueuedTaskCommands(_ command: String) async throws {
        let source = T2DurableSource(try view())
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        type(command, into: session)
        source.set(try view(terminal: .closed))
        await Task.yield()
        #expect(await controller.actions.isEmpty)
        #expect(toolTestText(session.tui.notices).contains("Session closed"))
    }

    @Test func footerShowsTaskCommands() throws {
        let source = T2DurableSource(try view())
        let session = DurableTuiSession(source: source, controller: T2DurableController(), terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        session.apply(source.hostCurrent())
        #expect(toolTestText(session.tui.footer).contains("/continue"))
        #expect(toolTestText(session.tui.footer).contains("/abort"))
    }
}
