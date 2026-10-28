import MiniTui
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentTui

struct D1tDurableSleepingTests {
    @Test func sleepingDescriptionShowsPhaseAndDeadlineOnOneLine() throws {
        let node: JSONValue = ["id": 3, "kind": "app.task", "conversationId": 1, "owner": 2,
            "background": true, "abortRequested": true,
            "state": ["status": "sleeping", "phase": "execute", "until": 1_700_000_000_000],
            "conversations": [4]]

        #expect(describeTask(try node.decode(TaskGraphNode.self)) ==
            "app.task #3: sleeping execute until 2023-11-14T22:13:20Z [background, aborting] owns conversation 4 parent task #2")
    }
}

extension D1tDurableSleepingTests {
    @MainActor @Test(arguments: ["retry", "poll"])
    func sleepingBackoffAndPollShowDeadlineWithoutWorkingIndicator(_ phase: String) throws {
        let tui = DurableTui(cwd: "/tmp", handlers: DurableTuiHandlers(
            submit: { _ in }, followUp: { _ in }, abort: {}, exit: {}, selectModel: {}, cycleThinking: {}
        ), terminal: ToolTestTerminal())
        defer { tui.stop() }
        let conversation = ConversationView(conversation: .init(id: rootConversationID), entries: [], docs: [
            "pi.live": ["run": ["taskId": 2, "inputs": []],
                "generation": ["attempt": 2, "retry": ["at": 1_700_000_000_000, "error": "Try later"],
                               "deferred": ["pollAt": 1_700_000_000_000]],
                "tools": [["callId": "sleeping", "name": "read", "status": "running"]]]
        ])
        func view(_ activity: DurableActivity, sleeping: [DurableSleepingTask] = []) -> DurableView {
            DurableView(session: .init(id: "sleeping", directory: "/tmp/session", cwd: "/tmp"),
                conversation: conversation, conversations: [], models: [], sleepingTasks: sleeping, activity: activity)
        }
        tui.apply(view(.progressing))
        #expect(tui.indicator != nil)
        tui.apply(view(.sleeping, sleeping: [
            .init(id: try TaskID(2), kind: "pi.generation", phase: phase, until: 1_700_000_000_000)
        ]))
        let rendered = toolTestText(tui.status)
        #expect(rendered.contains("pi.generation #2: waiting until 2023-11-14T22:13:20Z (\(phase))"))
        #expect(tui.indicator == nil)
        #expect(!toolTestText(tui.editor).contains("Retrying"))
        #expect(!toolTestText(tui.editor).contains("Running read"))
        #expect(!toolTestText(tui.editor).contains("Working"))
        #expect(toolTestText(tui.tasks).isEmpty)
        tui.apply(view(.progressing))
        #expect(tui.indicator != nil)
        #expect(toolTestText(tui.status).isEmpty)
    }
}
