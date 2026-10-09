import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftDurable
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import Testing
@testable import PiSwiftCodingAgentTui

private final class DurableRenderTerminal: Terminal {
    var columns = 100
    var rows = 30
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

@MainActor @Suite(.serialized) struct DurableRenderingTests {
    private func makeTui() -> DurableTui {
        DurableTui(cwd: "/tmp", handlers: DurableTuiHandlers(
            submit: { _ in }, followUp: { _ in }, abort: {}, exit: {}, selectModel: {}, cycleThinking: {}
        ), terminal: DurableRenderTerminal())
    }

    private func answer(_ text: String, stop: String = "stop", calls: [JSONValue] = [], tokens: Int = 100) -> JSONValue {
        ["role": "assistant", "content": .array([ ["type": "text", "text": .string(text)] ] + calls),
         "api": "openai-responses", "provider": "openai", "model": "test", "timestamp": 1,
         "stopReason": .string(stop), "usage": ["input": .number(Double(tokens)), "output": 0,
          "cacheRead": 0, "cacheWrite": 0, "totalTokens": .number(Double(tokens)),
          "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]]
    }

    private func entry(_ id: Int64, _ kind: String, _ message: JSONValue) throws -> EntryRecord {
        EntryRecord(id: try EntryID(id), conversationId: rootConversationID, kind: kind, model: [message])
    }

    private func view(_ entries: [EntryRecord] = [], docs: [String: JSONObject] = [:], graph: TaskGraph? = nil,
                      notices: [Notice] = []) -> DurableView {
        DurableView(session: .init(id: "test", directory: "/tmp/session", cwd: "/tmp"),
                    conversation: .init(conversation: .init(id: rootConversationID), entries: entries, docs: docs),
                    conversations: [.init(id: rootConversationID, label: "root")],
                    models: [.init(provider: "openai", modelId: "test", name: "Test", contextWindow: 1000)],
                    notices: notices, tasks: graph)
    }

    private func text(_ component: any Component) -> String {
        component.render(width: 100).joined(separator: "\n")
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    @Test func transcriptShowsUserAndAssistant() throws {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(view([try entry(2, "pi.user", ["role": "user", "content": "User text", "timestamp": 1]),
                        try entry(3, "pi.assistant", answer("Assistant text"))]))
        #expect(text(tui.chat).contains("User text"))
        #expect(text(tui.chat).contains("Assistant text"))
    }

    @Test func partialHandoverDoesNotDuplicateAndDropRemovesText() throws {
        let tui = makeTui(); defer { tui.stop() }
        let partial = answer("Partial text")
        tui.apply(view(docs: ["pi.live": ["generation": ["attempt": 1, "message": partial]]]))
        #expect(text(tui.chat).contains("Partial text"))
        tui.apply(view([try entry(2, "pi.assistant", answer("Final text"))]))
        #expect(!text(tui.chat).contains("Partial text"))
        #expect(text(tui.chat).components(separatedBy: "Final text").count == 2)
        tui.apply(view(docs: ["pi.live": ["generation": ["attempt": 1, "message": partial]]]))
        tui.apply(view())
        #expect(!text(tui.chat).contains("Partial text"))
    }

    @Test func repeatedCallIDsCreateSeparateCards() throws {
        let tui = makeTui(); defer { tui.stop() }
        let call: JSONValue = ["type": "toolCall", "id": "same", "name": "read", "arguments": ["path": "/tmp/a"]]
        let first = try entry(2, "pi.assistant", answer("", stop: "toolUse", calls: [call]))
        tui.apply(view([first]))
        let old = try #require(tui.tools["same"])
        tui.apply(view([first, try entry(3, "pi.assistant", answer("", stop: "toolUse", calls: [call]))]))
        #expect(tui.cards.count == 2)
        #expect(tui.tools["same"] !== old)
    }

    @Test func interruptedUnstreamedCallHasNoCard() throws {
        let tui = makeTui(); defer { tui.stop() }
        let call: JSONValue = ["type": "toolCall", "id": "skip", "name": "read", "arguments": ["path": "/tmp/a"]]
        tui.apply(view([try entry(2, "pi.assistant", answer("", stop: "aborted", calls: [call]))]))
        #expect(tui.cards.isEmpty)
    }

    @Test func streamedInterruptedCallShowsFinalState() throws {
        let tui = makeTui(); defer { tui.stop() }
        let call: JSONValue = ["type": "toolCall", "id": "skip", "name": "read", "arguments": ["path": "/tmp/a"]]
        tui.apply(view(docs: ["pi.live": ["generation": ["attempt": 1, "message": answer("", calls: [call])]]]))
        tui.apply(view([try entry(2, "pi.assistant", answer("", stop: "aborted", calls: [call]))]))
        #expect(tui.cards.count == 1)
        #expect(text(tui.chat).contains("Not run"))
    }

    @Test func queueNoticesAndContextAreVisible() throws {
        let tui = makeTui(); defer { tui.stop() }
        let docs: [String: JSONObject] = [
            "pi.agent": ["model": ["provider": "openai", "modelId": "test"]],
            "pi.usage": ["models": ["openai/test": ["input": 10, "output": 20, "cacheRead": 30, "cacheWrite": 40,
                "totalTokens": 100, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0.125]]],
                "tools": ["read": ["input": 1, "output": 2, "cacheRead": 3, "cacheWrite": 4,
                "totalTokens": 10, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0.025]]]],
            "pi.inbox": ["items": [["id": 4, "mode": "steer", "content": "Next step"],
                                    ["id": 5, "mode": "followUp", "content": [["type": "text", "text": "Then test"]]]]]
        ]
        tui.apply(view([try entry(2, "pi.assistant", answer("Done", tokens: 100))], docs: docs,
                       notices: [.init(id: 1, level: .warning, message: "Check input")]))
        #expect(text(tui.queue).contains("[steer] Next step"))
        #expect(text(tui.queue).contains("[followUp] Then test"))
        #expect(text(tui.notices).contains("Check input"))
        #expect(text(tui.footer).contains("10.0%"))
        #expect(text(tui.footer).contains("/tmp"))
        #expect(text(tui.footer).contains("↑11"))
        #expect(text(tui.footer).contains("↓22"))
        #expect(text(tui.footer).contains("R33"))
        #expect(text(tui.footer).contains("W44"))
        #expect(text(tui.footer).contains("$0.150"))
    }

    @Test func tasksNestUnderConversationOwner() throws {
        let tui = makeTui(); defer { tui.stop() }
        let root: JSONValue = ["id": 2, "kind": "pi.tool", "conversationId": 1, "background": false,
                               "abortRequested": false, "state": ["status": "running", "phase": "execute"], "conversations": [3]]
        let child: JSONValue = ["id": 4, "kind": "pi.generation", "conversationId": 3, "background": false,
                                "abortRequested": false, "state": ["status": "waiting", "phase": "tools", "on": [5], "policy": "allSettled"], "conversations": []]
        let graph = TaskGraph(tasks: ["2": try root.decode(TaskGraphNode.self), "4": try child.decode(TaskGraphNode.self)])
        tui.apply(view(graph: graph))
        let lines = text(tui.tasks).components(separatedBy: "\n")
        #expect(lines.contains { $0.contains("pi.tool") })
        #expect(lines.contains { $0.contains("pi.generation") && $0.hasPrefix("     ") })
    }

    @Test func liveSubagentShowsConversationNumber() {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(view(docs: ["pi.live": ["tools": [["callId": "child", "name": "subagent", "status": "running", "details": ["conversationId": 9]]]]]))
        #expect(text(tui.chat).contains("Subagent 9"))
        #expect(text(tui.chat).contains("/agents"))
    }

    @Test func toolDetailsPreserveDiffAndReadTruncation() throws {
        let tui = makeTui(); defer { tui.stop() }
        let edit: JSONValue = ["type": "toolCall", "id": "edit", "name": "edit", "arguments": ["path": "/tmp/no-file"]]
        let read: JSONValue = ["type": "toolCall", "id": "read", "name": "read", "arguments": ["path": "/tmp/a"]]
        let editResult: JSONValue = ["role": "toolResult", "toolCallId": "edit", "toolName": "edit", "timestamp": 1,
                                    "isError": false, "content": [["type": "text", "text": "Changed"]],
                                    "details": ["diff": "-7 old\n+7 replacement", "firstChangedLine": 7]]
        let readResult: JSONValue = ["role": "toolResult", "toolCallId": "read", "toolName": "read", "timestamp": 1,
                                    "isError": false, "content": [["type": "text", "text": "File text"]],
                                    "details": ["truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 1, "totalLines": 50, "maxLines": 1]]]
        let editEntry = try entry(3, "pi.tool-result", editResult)
        let decoded = try #require(editEntry.messages()?.first)
        guard case .toolResult(let result) = decoded else {
            Issue.record("The edit entry must contain a tool result.")
            return
        }
        let details = try #require(result.details?.value as? [String: Any])
        #expect(details["firstChangedLine"] as? Int == 7)
        tui.apply(view([try entry(2, "pi.assistant", answer("", stop: "toolUse", calls: [edit, read])),
                        editEntry, try entry(4, "pi.tool-result", readResult)]))
        #expect(text(tui.chat).contains("replacement"))
        #expect(text(tui.chat).contains("-7 old"))
        #expect(text(tui.chat).contains("+7 replacement"))
        tui.editor.handleInput("\u{000F}")
        #expect(text(tui.chat).contains("Truncated"))
        #expect(text(tui.chat).contains("50 lines"))
    }

    @Test func controlOExpandsSummary() throws {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(view([try entry(2, "pi.compaction", ["role": "user", "content": "Saved context detail", "timestamp": 1])]))
        #expect(!text(tui.chat).contains("Saved context detail"))
        tui.editor.handleInput("\u{000F}")
        #expect(tui.expanded)
        #expect(text(tui.chat).contains("Saved context detail"))
    }

    @Test func contextSkipsOldAndFailedAnswersAfterCompaction() throws {
        let tui = makeTui(); defer { tui.stop() }
        let docs: [String: JSONObject] = ["pi.agent": ["model": ["provider": "openai", "modelId": "test"]]]
        let old = try entry(2, "pi.assistant", answer("Old answer", tokens: 900))
        let summary = try entry(10, "pi.compaction", ["role": "user", "content": "Summary", "timestamp": 1])
        let failed = try entry(11, "pi.assistant", answer("Failed answer", stop: "error", tokens: 800))
        tui.apply(view([summary, old, failed], docs: docs))
        #expect(text(tui.footer).contains("?%"))
        tui.apply(view([summary, old, failed, try entry(12, "pi.assistant", answer("New answer", tokens: 200))], docs: docs))
        #expect(text(tui.footer).contains("20.0%"))
    }

    @Test func statusUsesPriorityAndThinkingBorder() {
        let tui = makeTui(); defer { tui.stop() }
        var live: JSONObject = ["run": ["taskId": 2, "inputs": []],
            "tools": [["callId": "status", "name": "read", "status": "running"]],
            "compactions": [["taskId": 3, "reason": "manual", "blocking": true, "attempt": 1]],
            "generation": ["attempt": 2, "retry": ["at": 1, "error": "Request failed"], "deferred": ["pollAt": 2]]]
        func apply() {
            tui.apply(view(docs: ["pi.live": live, "pi.agent": ["thinkingLevel": "high"]]))
        }
        apply()
        #expect(text(tui.editor).contains("Retrying (attempt 3): Request failed"))
        #expect(tui.editor.borderColor("border") == theme.getThinkingBorderColor("high")("border"))
        live["generation"] = ["attempt": 2, "deferred": ["pollAt": 2]]
        apply()
        #expect(text(tui.editor).contains("Waiting for deferred response"))
        live["generation"] = nil
        apply()
        #expect(text(tui.editor).contains("Compacting (manual)"))
        live["compactions"] = nil
        apply()
        #expect(text(tui.editor).contains("Running read"))
        live["tools"] = nil
        apply()
        #expect(text(tui.editor).contains("Working"))
        live["run"] = nil
        apply()
        #expect(!text(tui.editor).contains("Working"))
    }

    @Test func writeQueueAndLastFourNotices() {
        let tui = makeTui(); defer { tui.stop() }
        let notices = (1...6).map { Notice(id: $0, level: .info, message: "Notice \($0)") }
        tui.apply(view(docs: ["pi.inbox": ["items": [["id": 2, "mode": "write", "entry": ["kind": "custom.note"]]]]],
                       notices: notices))
        #expect(text(tui.queue).contains("[write] <custom.note>"))
        #expect(!text(tui.notices).contains("Notice 1"))
        #expect(!text(tui.notices).contains("Notice 2"))
        for id in 3...6 { #expect(text(tui.notices).contains("Notice \(id)")) }
        tui.apply(view())
        #expect(text(tui.queue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(text(tui.notices).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func taskStatesFlagsAndExplicitOwner() throws {
        let tui = makeTui(); defer { tui.stop() }
        func node(_ id: Int64, _ state: JSONValue, owner: Int64? = nil) throws -> TaskGraphNode {
            var json: JSONObject = ["id": .number(Double(id)), "kind": "custom.task", "conversationId": 1,
                "background": true, "abortRequested": true, "state": state, "conversations": [7, 8]]
            if let owner { json["owner"] = .number(Double(owner)) }
            return try JSONValue.object(json).decode(TaskGraphNode.self)
        }
        let pending = try node(2, ["status": "pending", "phase": "start"])
        let running = try node(3, ["status": "running", "phase": "execute"], owner: 2)
        let waiting = try node(4, ["status": "waiting", "phase": "join", "on": [5, 6], "policy": "allSettled"])
        let completing = try node(5, ["status": "completing", "outcome": "succeeded"])
        #expect(describeTask(pending).contains("pending start"))
        #expect(describeTask(running).contains("running execute"))
        #expect(describeTask(waiting).contains("waiting on 5, 6"))
        #expect(describeTask(completing).contains("completing (succeeded)"))
        #expect(describeTask(pending).contains("[background, aborting]"))
        #expect(describeTask(pending).contains("owns conversation 7, 8"))
        tui.apply(view(graph: TaskGraph(tasks: ["2": pending, "3": running])))
        #expect(text(tui.tasks).components(separatedBy: "\n").contains { $0.hasPrefix("     ") && $0.contains("#3") })
    }

    @Test func liveReadDetailsUseFoundationNumbersAndPendingSlotsStayHidden() throws {
        let tui = makeTui(); defer { tui.stop() }
        let slot: JSONValue = ["callId": "live-read", "name": "read", "status": "running", "output": "Live file text",
            "details": ["truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 2, "totalLines": 75, "maxLines": 2]]]
        let typed = try slot.decode(ToolSlot.self)
        let details = try #require(typed.details)
        let foundation = try #require(foundationJSON(from: details) as? [String: Any])
        let truncation = try #require(foundation["truncation"] as? [String: Any])
        #expect(truncation["totalLines"] as? Int == 75)
        tui.apply(view(docs: ["pi.live": ["tools": [slot, ["callId": "pending", "name": "read", "status": "pending"]]]]))
        #expect(tui.tools["pending"] == nil)
        #expect(tui.cards.count == 1)
        tui.editor.handleInput("\u{000F}")
        #expect(text(tui.chat).contains("Live file text"))
        #expect(text(tui.chat).contains("showing 2 of 75 lines"))
    }
}
