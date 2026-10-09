import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class DurableInputSource: DurableViewSource {
    private struct State {
        var view: DurableView
        var listener: (@Sendable () -> Void)?
        var cancelled = false
    }
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "durable-input-test")
    init(_ view: DurableView) { state = Mutex(State(view: view)) }
    func current() -> DurableView { state.withLock { $0.view } }
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> DurableViewSubscription {
        state.withLock { $0.listener = listener }
        return DurableViewSubscription { [self] in state.withLock { $0.listener = nil; $0.cancelled = true } }
    }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func update(_ view: DurableView) async {
        state.withLock { $0.view = view }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                state.withLock { $0.listener }?()
                continuation.resume()
            }
        }
    }
}

private actor RecordingDurableController: DurableController {
    enum Action: Sendable, Equatable {
        case submit(String, SubmitWhenBusy)
        case compact(String?)
        case abort, thinking, tasks
        case model(ModelRef)
        case conversation(ConversationID)
    }
    nonisolated let events: AsyncStream<Action>
    private let output: AsyncStream<Action>.Continuation
    init() { (events, output) = AsyncStream.makeStream() }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) { output.yield(.submit(text, whenBusy)) }
    func compact(instructions: String?) { output.yield(.compact(instructions)) }
    func abort() { output.yield(.abort) }
    func cycleThinking() { output.yield(.thinking) }
    func setModel(_ model: ModelRef) { output.yield(.model(model)) }
    func toggleTasks() { output.yield(.tasks) }
    func switchConversation(_ id: ConversationID) { output.yield(.conversation(id)) }
}

private final class DurableLifecycleTerminal: Terminal {
    var columns = 100
    var rows = 24
    var kittyProtocolActive = false
    var input: ((String) -> Void)?
    var stopped = false
    var writes = ""
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    init() { (started, signal) = AsyncStream.makeStream() }
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        input = onInput
        signal.yield(())
    }
    func stop() { stopped = true; input = nil }
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
struct DurableInputTests {
    private func view(notices: [Notice] = []) throws -> DurableView {
        let child = try ConversationID(9)
        return DurableView(session: .init(id: "input", directory: "/tmp/durable-input", cwd: "/tmp"),
            conversation: .init(conversation: .init(id: rootConversationID), entries: [],
                docs: ["pi.agent": ["model": ["provider": "fake", "modelId": "current"]],
                       "pi.live": ["run": ["taskId": 2, "inputs": []]]]),
            conversations: [.init(id: rootConversationID, label: "main"), .init(id: child, label: "subagent 9", title: "Child task")],
            models: [.init(provider: "fake", modelId: "other", name: "Other", contextWindow: 1000),
                     .init(provider: "fake", modelId: "current", name: "Current", contextWindow: 1000)], notices: notices)
    }
    private func session(_ source: DurableInputSource, _ controller: RecordingDurableController,
                         exit: @escaping () -> Void = {}) -> DurableTuiSession {
        DurableTuiSession(source: source, controller: controller, terminal: ToolTestTerminal(), exit: exit)
    }
    private func type(_ text: String, into session: DurableTuiSession) {
        session.tui.editor.handleInput(text)
        session.tui.editor.handleInput("\r")
    }

    @Test func editorSendsSteerFollowUpAbortAndThinking() async throws {
        let source = DurableInputSource(try view())
        let controller = RecordingDurableController()
        let session = session(source, controller)
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("  Do the work  ", into: session)
        #expect(await events.next() == .submit("Do the work", .steer))
        #expect(session.tui.editor.getText().isEmpty)
        session.tui.editor.handleInput("  Next step  ")
        session.tui.editor.handleInput("\u{001B}\r")
        #expect(await events.next() == .submit("Next step", .followUp))
        #expect(session.tui.editor.getText().isEmpty)
        session.tui.editor.handleInput("\u{001B}")
        #expect(await events.next() == .abort)
        session.tui.editor.handleInput("\u{001B}[Z")
        #expect(await events.next() == .thinking)
    }

    @Test func slashCommandsSendTasksAndCompaction() async throws {
        let source = DurableInputSource(try view())
        let controller = RecordingDurableController()
        let session = session(source, controller)
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("/tasks", into: session)
        #expect(await events.next() == .tasks)
        type("/compact keep the shortlist", into: session)
        #expect(await events.next() == .compact("keep the shortlist"))
        type("/compact", into: session)
        #expect(await events.next() == .compact(nil))
        type("/compactly", into: session)
        #expect(await events.next() == .submit("/compactly", .steer))
    }

    @Test func modelSelectorStartsWithCurrentAndFilters() async throws {
        let source = DurableInputSource(try view())
        let controller = RecordingDurableController()
        let session = session(source, controller)
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("/model", into: session)
        let selector = try #require(session.tui.editorContainer.children.first as? ListSelector)
        let rendered = toolTestText(selector)
        #expect(rendered.contains("Select model:"))
        #expect(try #require(rendered.range(of: "current")).lowerBound < #require(rendered.range(of: "other")).lowerBound)
        selector.handleInput("\r")
        #expect(await events.next() == .model(ModelRef(provider: "fake", modelId: "current")))
        #expect(session.tui.editorContainer.children.first === session.tui.editor)
        session.tui.editor.handleInput("\u{000C}")
        let filtered = try #require(session.tui.editorContainer.children.first as? ListSelector)
        filtered.handleInput("other")
        #expect(!toolTestText(filtered).contains("current"))
        filtered.handleInput("\r")
        #expect(await events.next() == .model(ModelRef(provider: "fake", modelId: "other")))
    }

    @Test func agentsSelectorStartsWithNewestAndCancels() async throws {
        let source = DurableInputSource(try view())
        let controller = RecordingDurableController()
        let session = session(source, controller)
        defer { session.stop() }
        var events = controller.events.makeAsyncIterator()
        type("/agents", into: session)
        let selector = try #require(session.tui.editorContainer.children.first as? ListSelector)
        #expect(toolTestText(selector).contains("Switch to:"))
        #expect(toolTestText(selector).contains("(shown)"))
        selector.handleInput("\r")
        #expect(await events.next() == .conversation(try ConversationID(9)))
        type("/agents", into: session)
        let cancelled = try #require(session.tui.editorContainer.children.first as? ListSelector)
        cancelled.handleInput("\u{001B}")
        #expect(session.tui.editorContainer.children.first === session.tui.editor)
    }

    @Test func controlCExitsWithTextAndControlDExitsEmptyEditor() throws {
        var exits = 0
        let source = DurableInputSource(try view())
        let session = session(source, RecordingDurableController(), exit: { exits += 1 })
        defer { session.stop() }
        session.tui.editor.handleInput("draft")
        session.tui.editor.handleInput("\u{0003}")
        #expect(exits == 1)
        session.tui.editor.setText("")
        session.tui.editor.handleInput("\u{0004}")
        #expect(exits == 2)
    }

    @Test func backgroundSourceUpdatesHopToMainActorAndStopCancels() async throws {
        let source = DurableInputSource(try view())
        let session = session(source, RecordingDurableController())
        session.subscribe()
        defer { session.stop() }
        await source.update(try view(notices: [.init(id: 1, level: .info, message: "Queue update")]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !toolTestText(session.tui.notices).contains("Queue update"), ContinuousClock.now < deadline { await Task.yield() }
        #expect(toolTestText(session.tui.notices).contains("Queue update"))
        session.stop()
        #expect(source.cancelled)
        await source.update(try view(notices: [.init(id: 2, level: .info, message: "Stopped update")]))
        #expect(!toolTestText(session.tui.notices).contains("Stopped update"))
    }

    @Test func fullscreenLayoutKeepsDockAndScrollsTranscript() throws {
        let source = DurableInputSource(try view())
        let session = session(source, RecordingDurableController())
        defer { session.stop() }
        #expect(session.tui.ui.mode == .altScreen)
        for index in 0..<30 { session.tui.chat.addChild(Text("message \(index)", paddingX: 0, paddingY: 0)) }
        session.tui.apply(source.current())
        let frame = renderLayoutFrame(root: session.tui.layoutRoot, width: 100, height: 14, requestRender: {})
        let text = frame.lines.map(stripTerminalSequences).joined(separator: "\n")
        #expect(frame.primaryScrollView === session.tui.transcript)
        #expect(text.contains("message 29"))
        #expect(!text.contains("message 0"))
        #expect(text.contains("/tasks"))
        #expect(frame.lines.count == 14)
    }
    @Test(arguments: [false, true])
    func runLoopStopsOnExitOrCancellation(_ cancel: Bool) async throws {
        let source = DurableInputSource(try view())
        let terminal = DurableLifecycleTerminal()
        let controller = RecordingDurableController()
        let run = Task { await runDurableTui(view: source, controller: controller,
            settings: SettingsManager.inMemory(), terminal: terminal) }
        var started = terminal.started.makeAsyncIterator()
        _ = await started.next()
        if cancel { run.cancel() } else { terminal.input?("\u{0003}") }
        await run.value
        #expect(source.cancelled)
        #expect(terminal.stopped)
        #expect(terminal.writes.contains("\u{001B}[?1049h"))
        #expect(terminal.writes.contains("\u{001B}[?1049l"))
    }

}
