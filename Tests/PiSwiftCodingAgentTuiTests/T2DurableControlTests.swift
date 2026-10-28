import MiniTui
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class T2DurableSource: DurableViewSource {
    private let view: Mutex<DurableView>
    init(_ view: DurableView) { self.view = Mutex(view) }
    func current() -> DurableView { view.withLock { $0 } }
    func set(_ value: DurableView) { view.withLock { $0 = value } }
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription {
        DurableViewSubscription {}
    }
}

private actor T2DurableController: DurableController {
    enum Action: Sendable, Equatable {
        case retry(TaskID), abortTask(TaskID), abort, submit(String)
    }
    nonisolated let events: AsyncStream<Action>
    private let output: AsyncStream<Action>.Continuation
    private(set) var actions: [Action] = []
    init() { (events, output) = AsyncStream.makeStream() }
    private func record(_ action: Action) { actions.append(action); output.yield(action) }
    func retryTask(_ id: TaskID) { record(.retry(id)) }
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
    private func view(parked count: Int = 1, terminal: DurableSessionTerminal? = nil) throws -> DurableView {
        let blocked = try (0..<count).map {
            DurableBlockedTask(id: try TaskID(Int64(7 + $0)), kind: "pi.tool", reason: .restartLimit, restarts: 5)
        }
        return DurableView(session: .init(id: "controls", directory: "/tmp/controls", cwd: "/tmp"),
            conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
            conversations: [], models: [], terminal: terminal, blockedTasks: blocked,
            activity: count == 0 ? .idle : .parked)
    }

    private func type(_ text: String, into session: DurableTuiSession) {
        session.tui.editor.handleInput(text)
        session.tui.editor.handleInput("\r")
    }

    @Test(arguments: ["/retry 42", "/abort 42", "/retry", "/abort"])
    func taskCommandsUseExplicitIdOrTheSingleParkedTask(_ command: String) async throws {
        let source = T2DurableSource(try view())
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type(command, into: session)
        let id = try TaskID(command.contains("42") ? 42 : 7)
        #expect(await events.next() == (command.hasPrefix("/retry") ? .retry(id) : .abortTask(id)))
        #expect(session.tui.editor.getText().isEmpty)
        session.tui.editor.handleInput("\u{001B}")
        #expect(await events.next() == .abort)
    }

    @Test(arguments: ["/retry", "/abort"])
    func defaultTaskIdUsesTheCurrentView(_ command: String) async throws {
        let source = T2DurableSource(try view(parked: 0))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        // No listener notification is sent before this command.
        source.set(try view())
        var events = controller.events.makeAsyncIterator()
        type(command, into: session)
        let id = try TaskID(7)
        #expect(await events.next() == (command == "/retry" ? .retry(id) : .abortTask(id)))
    }

    @Test(arguments: [
        ("/retry", 0), ("/abort", 0), ("/retry", 2), ("/abort", 2),
        ("/retry no", 1), ("/abort 0", 1), ("/retry -1", 1),
        ("/abort 9007199254740992", 1), ("/retry 7 8", 1), ("/abort 7 8", 1)
    ])
    func invalidTaskCommandShowsHelpWithoutSubmittingInput(_ command: String, _ parked: Int) async throws {
        let source = T2DurableSource(try view(parked: parked))
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        type(command, into: session)
        await Task.yield()
        #expect(await controller.actions.isEmpty)
        let verb = command.hasPrefix("/retry") ? "/retry" : "/abort"
        #expect(toolTestText(session.tui.notices).contains("Use \(verb) <id>."))
        #expect(toolTestText(session.tui.notices).contains("Omit the ID only when one task is parked."))
    }

    @Test(arguments: ["/retrying", "/aborting"])
    func commandPrefixesRemainNormalInput(_ text: String) async throws {
        let source = T2DurableSource(try view())
        let controller = T2DurableController()
        let session = DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: {})
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type(text, into: session)
        #expect(await events.next() == .submit(text))
    }

    @Test(arguments: ["/retry 7", "/abort 7", "/retry", "/abort"])
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
        #expect(exits == 1)
        #expect(toolTestText(session.tui.notices).contains("Session failed: Storage failed"))
    }

    @Test(arguments: ["/retry 7", "/abort 7"])
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
        session.apply(source.current())
        #expect(toolTestText(session.tui.footer).contains("/retry [id]"))
        #expect(toolTestText(session.tui.footer).contains("/abort [id]"))
    }
}
