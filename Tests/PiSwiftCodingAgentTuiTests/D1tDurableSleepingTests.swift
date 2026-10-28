import PiSwiftChord
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
