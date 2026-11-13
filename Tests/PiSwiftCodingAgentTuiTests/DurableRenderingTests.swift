import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
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
                    notices: notices, tasks: graph,
                    // v1.5.2 D11: Host activity is explicit, including compaction-only work.
                    activity: docs["pi.live"].map { $0["run"] != nil || $0["compactions"] != nil || $0["tools"] != nil ? .progressing : .idle } ?? .idle)
    }

    private func text(_ component: any Component) -> String {
        component.render(width: 100).joined(separator: "\n")
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    @Test(arguments: ["pi.live", "pi.agent", "pi.inbox"])
    func malformedPresentDocumentShowsError(_ kind: String) {
        let tui = makeTui(); defer { tui.stop() }
        let document: JSONObject
        switch kind {
        case "pi.live": document = ["nestedTools": "invalid"]
        case "pi.agent": document = ["modelTools": 3]
        default: document = ["items": "invalid"]
        }
        tui.apply(view(docs: [kind: document]))
        #expect(!text(tui.notices).isEmpty) // v1.5.2 D11: Typed decode diagnostic retains the source error.
        if kind == "pi.agent" { #expect(text(tui.notices).contains("Agent:")) } // v1.5.2 D11: Typed host diagnostic.
        tui.apply(view())
        #expect(text(tui.notices).isEmpty)
    }

    @Test func applicationEntriesShowKindDataAndValidUserContent() throws {
        let tui = makeTui(); defer { tui.stop() }
        let input = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "app.request",
            model: [["role": "user", "content": "Custom user input", "timestamp": 1]], data: ["ticket": 42])
        let display = EntryRecord(id: try EntryID(3), conversationId: rootConversationID, kind: "app.progress",
            model: [["role": "invalid", "content": "Invalid model content"]], data: "Build complete")
        let unknown = EntryRecord(id: try EntryID(4), conversationId: rootConversationID, kind: "pi.future")
        tui.apply(view([input, display, unknown]))
        let rendered = text(tui.chat)
        for value in ["<app.request>", "ticket", "42", "Custom user input", "<app.progress>", "Build complete", "<pi.future>"] {
            #expect(rendered.contains(value))
        }
        #expect(!rendered.contains("Invalid model content"))
        #expect(shortData(.string(String(repeating: "x", count: 500))).count == 241)
    }

    @Test func displayOnlyWriteDoesNotEndStreamingOrStayQueued() throws {
        let tui = makeTui(); defer { tui.stop() }
        let live: JSONObject = ["run": ["taskId": 2, "inputs": []],
            "generation": ["attempt": 1, "message": answer("Answer in progress")]]
        tui.apply(view(docs: ["pi.live": live]))
        let display = EntryRecord(id: try EntryID(3), conversationId: rootConversationID,
            kind: "app.progress", data: ["step": "Saved file"])
        tui.apply(view([display], docs: ["pi.live": live]))
        let rendered = text(tui.chat)
        #expect(rendered.contains("Saved file"))
        #expect(rendered.components(separatedBy: "Answer in progress").count == 2)
        #expect(text(tui.editor).contains("Working"))
        #expect(text(tui.queue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func libraryCustomQueueAndImmediateWriteRenderWhileBusy() async throws {
        let tui = makeTui(); defer { tui.stop() }
        let setup = HarnessChatSetup()
        let response = HarnessGatedResponse(message: chatAssistant("First answer"))
        setup.models.setResponses([response.step, .message(chatAssistant("Follow-up answer"))])
        let opened = try await openChat(setup: setup)
        do {
            _ = try await opened.root.submit(.input(content: .text("Start")), context: .background)
            await response.reached.wait()
            let queued = try await opened.root.submit(.input(content: .text("Queued custom input"),
                entry: InputEntry(kind: "app.request", data: ["request": 42]), whenBusy: .followUp), context: .background)
            let write = try await opened.root.submit(.write(entry: EntryDraft(kind: "app.progress", data: "Immediate display")), context: .background)
            #expect(try await write.wait(context: .background).status == "done")
            let inbox = try await opened.harness.snapshot(InboxDoc, conversationId: opened.root.id, context: .background)
            let live = try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)
            let docs: [String: JSONObject] = [
                "pi.inbox": try #require(JSONValue(encoding: inbox).objectValue),
                "pi.live": try #require(JSONValue(encoding: live).objectValue)
            ]
            tui.apply(view(try await allEntries(opened.root), docs: docs))
            #expect(text(tui.chat).contains("Immediate display"))
            #expect(text(tui.queue).contains("[followUp] <app.request> Queued custom input"))
            #expect(!text(tui.queue).contains("app.progress"))
            #expect(try #require(inbox).items.map(\.id) == [queued.id])
            #expect(try #require(live).run != nil)
            response.release()
            _ = try await queued.wait(context: .background)
            tui.apply(view(try await allEntries(opened.root)))
            #expect(text(tui.chat).contains("<app.request>"))
            #expect(text(tui.chat).contains("Queued custom input"))
            #expect(text(tui.queue).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try await opened.harness.close(context: .background)
        } catch {
            response.release()
            try await opened.harness.close(context: .background)
            throw error
        }
    }

    @Test func queuedCustomInputsAndWritesShowEntries() {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(view(docs: ["pi.inbox": ["items": [
            ["id": 2, "mode": "steer", "content": "Custom steering", "entry": ["kind": "app.input", "data": ["ticket": 8]]],
            ["id": 3, "mode": "followUp", "content": [["type": "text", "text": "Custom follow-up"]], "entry": ["kind": "app.later"]],
            ["id": 4, "mode": "write", "entry": ["kind": "app.note", "data": "Saved note",
                "model": [["role": "user", "content": "Write content", "timestamp": 1]]]]
        ]]]))
        let rendered = text(tui.queue)
        for value in ["[steer] <app.input> Custom steering", "ticket", "[followUp] <app.later> Custom follow-up",
                      "[write] <app.note>", "Saved note", "Write content"] { #expect(rendered.contains(value)) }
    }

    @Test func retainedCompactionFailureRestoresAndSummaryClearsIt() throws {
        let tui = makeTui(); defer { tui.stop() }
        let failure = CompactionFailure(taskId: try TaskID(7), reason: .manual, error: "Summary request failed")
        func docs(_ live: LiveState) throws -> [String: JSONObject] {
            ["pi.live": try #require(JSONValue(encoding: live).objectValue)]
        }
        tui.apply(view(docs: try docs(LiveState(compactions: [.init(taskId: try TaskID(8), reason: .manual,
            blocking: false, attempt: 1)], compactionFailure: failure))))
        #expect(text(tui.editor).contains("Compacting"))
        tui.apply(view(docs: try docs(LiveState(compactionFailure: failure))))
        #expect(text(tui.notices).contains("Summary request failed"))
        #expect(!text(tui.editor).contains("Compacting"))
        let restored = makeTui(); defer { restored.stop() }
        restored.apply(view(docs: try docs(LiveState(compactionFailure: failure))))
        #expect(text(restored.notices).contains("task #7"))
        let summary = try entry(9, "pi.compaction", ["role": "user", "content": "Saved summary", "timestamp": 1])
        restored.apply(view([summary], docs: try docs(LiveState())))
        #expect(!text(restored.notices).contains("Summary request failed"))
        #expect(restored.summaries.count == 1)
    }

    @Test func terminalFailureKeepsFirstCauseAndShowsItOnce() {
        let tui = makeTui(); defer { tui.stop() }
        func failed(_ message: String) -> DurableView {
            let value = view(notices: [.init(id: 1, level: .error, message: message)])
            return DurableView(session: value.session, conversation: .init(conversation: d11HostView(value).transcript.conversation, entries: [], docs: d11HostView(value).transcript.docs),
                conversations: value.conversations, models: value.models, notices: value.notices,
                terminal: .failed(message: message))
        }
        tui.apply(failed("Storage commit failed"))
        tui.apply(failed("Storage commit failed"))
        #expect(text(tui.notices).components(separatedBy: "Storage commit failed").count == 2)
        tui.apply(view())
        // v1.5.2 D11: Storage failure offers recovery and explicit quit.
        #expect(text(tui.notices).contains("Session failed: Storage commit failed · /reopen or Ctrl-D to quit"))
        #expect(tui.terminalState == .failed(message: "Storage commit failed"))
    }

    @Test func taskGraphShowsExplicitParentOwnership() throws {
        let node: JSONValue = ["id": 3, "kind": "app.task", "conversationId": 1, "owner": 2,
            "background": false, "abortRequested": true, "state": ["status": "running", "phase": "execute"], "conversations": []]
        #expect(describeTask(try node.decode(TaskGraphNode.self)).contains("parent task #2"))
    }

    @Test func dockHeightUpdatesAfterTheFirstFrame() {
        let tui = makeTui(); defer { tui.stop() }
        func frame() -> String {
            renderLayoutFrame(root: tui.layoutRoot, width: 100, height: 20, requestRender: {})
                .lines.map(stripTerminalSequences).joined(separator: "\n")
        }
        tui.apply(view())
        #expect(!frame().contains("Queued custom input"))
        let updated = view(docs: [
            "pi.inbox": ["items": [["id": 2, "mode": "followUp", "content": "Queued custom input"]]],
            "pi.live": ["compactionFailure": ["taskId": 3, "reason": "manual", "error": "Summary failed"]]
        ])
        tui.apply(updated)
        #expect(frame().contains("Queued custom input"))
        #expect(frame().contains("Summary failed"))
        tui.apply(DurableView(session: updated.session, conversation: .init(conversation: d11HostView(updated).transcript.conversation, entries: [], docs: d11HostView(updated).transcript.docs),
            conversations: updated.conversations, models: updated.models, terminal: .failed(message: "Storage failed")))
        #expect(frame().contains("Session failed: Storage failed"))
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

    // v1.5.2 D11: The committed tool result wins after a hook changes its output.
    @Test func hookReplacedToolResultUsesCommittedEntry() throws {
        let tui = makeTui(); defer { tui.stop() }
        let call: JSONValue = ["type": "toolCall", "id": "hooked", "name": "read",
                               "arguments": ["path": "/tmp/a"]]
        let assistant = try entry(2, "pi.assistant", answer("", stop: "toolUse", calls: [call]))
        tui.apply(view([assistant], docs: ["pi.live": [
            "tools": [["callId": "hooked", "name": "read", "status": "running", "output": "Original output"]]
        ]]))
        tui.editor.handleInput("\u{000F}")
        #expect(text(tui.chat).contains("Original output"))
        let committed: JSONValue = ["role": "toolResult", "toolCallId": "hooked", "toolName": "read",
                                    "timestamp": 1, "isError": false,
                                    "content": [["type": "text", "text": "Hook replacement"]]]
        tui.apply(view([assistant, try entry(3, "pi.tool-result", committed)]))
        #expect(text(tui.chat).contains("Hook replacement"))
        #expect(!text(tui.chat).contains("Original output"))
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

extension DurableRenderingTests {
    private func workView(docs: [String: JSONObject] = [:], graph: TaskGraph? = nil,
                          blocked: [DurableBlockedTask] = [], sleeping: [DurableSleepingTask] = [],
                          activity: DurableActivity = .idle, inputs: [InboxItem] = [],
                          notices: [Notice] = [], terminal: DurableSessionTerminal? = nil) -> DurableView {
        // v1.5.2 D11: Queued input now belongs to the typed inbox document.
        var documents = docs
        if !inputs.isEmpty {
            let saved = documents["pi.inbox"].flatMap { try? JSONValue.object($0).decode(InboxState.self) }?.items ?? []
            let ids = Set(saved.map(\.id))
            documents["pi.inbox"] = try? JSONValue(encoding: InboxState(items: inputs.filter { !ids.contains($0.id) } + saved)).objectValue
        }
        let base = view(docs: documents, graph: graph, notices: notices)
        return DurableView(session: base.session, conversation: .init(conversation: d11HostView(base).transcript.conversation, entries: [], docs: d11HostView(base).transcript.docs),
            conversations: base.conversations, models: base.models, notices: notices, tasks: graph,
            terminal: terminal, blockedTasks: blocked, sleepingTasks: sleeping,
            activity: activity, queuedInputs: inputs)
    }

    // v1.5.2 D11: Ended outcomes replace restart-limit parking and retry actions.
    @Test func endedTaskOutcomeShowsSavedReasonWithoutRetryAction() throws {
        let tui = makeTui(); defer { tui.stop() }
        let base = workView()
        let outcome = DurableTaskOutcome(id: try TaskID(2), kind: "pi.tool",
            conversationId: rootConversationID, outcome: .orphaned(reason: "Saved task cannot resume"))
        let snapshot = DurableHostView(legacy: base,
            transcript: TranscriptView(conversation: d11HostView(base).transcript.conversation, docs: [:], items: []),
            mode: .write, outcomes: [outcome])
        tui.apply(snapshot)
        let rendered = text(tui.tasks) + text(tui.status) + text(tui.notices)
        #expect(rendered.contains("Saved task cannot resume"))
        #expect(!rendered.contains("/retry"))
        #expect(tui.indicator == nil)
    }

    @Test func queuedInputsAfterFailedRunKeepModeContentAndWrites() throws {
        let tui = makeTui(); defer { tui.stop() }
        let inputs = [InboxItem(id: try SubmissionID(8), mode: .steer, content: "Check the failure",
                               inputEntry: InputEntry(kind: "app.request", data: ["ticket": 42])),
                      InboxItem(id: try SubmissionID(9), mode: .followUp,
                               content: [["type": "text", "text": "Then run tests"]])]
        let failure: JSONObject = ["generation": ["attempt": 1, "message": answer("Request failed", stop: "error")]]
        tui.apply(workView(docs: ["pi.live": failure,
            "pi.inbox": ["items": [["id": 10, "mode": "write", "entry": ["kind": "app.note", "data": "Saved note"]]]]],
            inputs: inputs))
        let rendered = text(tui.queue)
        #expect(rendered.contains("Queued inputs (no active run):"))
        #expect(rendered.contains("[steer] <app.request> Check the failure"))
        #expect(rendered.contains("ticket"))
        #expect(rendered.contains("[followUp] Then run tests"))
        #expect(try #require(rendered.range(of: "Check the failure")).lowerBound < #require(rendered.range(of: "Then run tests")).lowerBound)
        #expect(rendered.contains("[write] <app.note>"))
        #expect(rendered.contains("Saved note"))
        #expect(tui.indicator == nil)
    }

    @Test func queueSummaryDoesNotDuplicateInboxInputs() throws {
        let tui = makeTui(); defer { tui.stop() }
        let item = InboxItem(id: try SubmissionID(8), mode: .steer, content: "Queued once")
        let inbox = try #require(JSONValue(encoding: InboxState(items: [item])).objectValue)
        tui.apply(workView(docs: ["pi.inbox": inbox, "pi.live": ["run": ["taskId": 2, "inputs": []]]], inputs: [item]))
        #expect(text(tui.queue).components(separatedBy: "Queued once").count == 2)
        #expect(!text(tui.queue).contains("no active run"))
    }

    // v1.5.2 D11: Untyped historical notices retain their displayMessage.
    @Test func taskNoticesAndSessionFailureHaveDistinctText() throws {
        let tui = makeTui(); defer { tui.stop() }
        let id = try TaskID(2)
        let items: [Notice] = [
            // v1.5.2 D11: A typed interrupted report replaces the parked notice.
            .init(id: 1, level: .warning, message: "Cut off 5 times", taskId: id, taskKind: "pi.tool",
                reportInfo: .taskInterrupted(task: .init(id: id, kind: "pi.tool", conversationId: rootConversationID),
                    reason: .restartLimit, restarts: 5)),
            .init(id: 2, level: .error, message: "Tool failed", category: .taskFault, taskId: id, taskKind: "pi.tool"),
            .init(id: 3, level: .warning, message: "Check runtime", category: .report, taskId: id, taskKind: "pi.tool"),
            .init(id: 4, level: .error, message: "Storage failed", category: .sessionFailed)
        ]
        tui.apply(workView(notices: Array(items.prefix(3))))
        #expect(tui.terminalState == nil)
        #expect(!text(tui.notices).contains("Session failed"))
        tui.apply(workView(notices: items))
        let rendered = text(tui.notices)
        #expect(rendered.contains("Task interrupted #2 (pi.tool) [restart_limit, 5 restarts]: Cut off 5 times")) // v1.5.2 D11: Show typed reason and count.
        #expect(rendered.contains("Task fault: Tool failed"))
        #expect(rendered.contains("Runtime report: Check runtime"))
        #expect(rendered.contains("Session failed: Storage failed"))
        // v1.5.2 D11: Parked-task formatter checks are replaced by the typed interrupted report above.
    }

    @Test(arguments: [false, true], [false, true])
    func extensionErrorNoticesShowOptionalSources(_ hasExtension: Bool, _ hasTask: Bool) throws {
        let tui = makeTui(); defer { tui.stop() }
        let task = hasTask ? ReportTask(id: try TaskID(2), kind: "pi.tool", conversationId: rootConversationID) : nil
        let name = hasExtension ? "coding-agent" : nil
        let info = ReportInfo.extensionError(extension: name, task: task, conversationId: rootConversationID)
        let notice = Notice(id: 1, level: .error, message: "Hook failed", category: .extensionError,
                            taskId: task?.id, taskKind: task?.kind, reportType: info.kind,
                            extensionName: name, conversationId: rootConversationID, reportInfo: info)
        tui.apply(workView(notices: [notice]))
        let taskText = hasTask ? " #2 (pi.tool)" : ""
        let sourceText = hasExtension ? " [extension: coding-agent]" : ""
        let expected = "Extension error\(taskText)\(sourceText) [conversation #1]: Hook failed" // v1.5.2 D11: Show report conversation identity.
        #expect(describeNotice(notice) == expected)
        #expect(text(tui.notices).contains(expected))
        #expect(!text(tui.notices).contains("Session failed"))
        #expect(tui.terminalState == nil)
    }

    // v1.5.2 D11: Typed report metadata supplies IDs; legacy categories use displayMessage.
    @Test(arguments: [
        (Notice.Category.operation, "Message", "Message"),
        (.report, "Runtime report: Message", "Runtime report: Message"),
        // v1.5.2 D11: Interrupted-task reports are checked with typed metadata above.
        (.taskFault, "Task fault: Message", "Task fault: Message"),
        (.sessionFailed, "Session failed: Message", "Session failed: Message")
    ])
    func existingNoticeCategoriesKeepTheirText(_ category: Notice.Category, _ withoutTask: String, _ withTask: String) throws {
        #expect(describeNotice(.init(id: 1, level: .error, message: "Message", category: category)) == withoutTask)
        #expect(describeNotice(.init(id: 2, level: .error, message: "Message", category: category,
                                    taskId: try TaskID(2), taskKind: "pi.tool")) == withTask)
    }

    @Test(arguments: [
        (Notice.Category.report, "Runtime report: Message"),
        // v1.5.2 D11: Typed interrupted-task metadata replaces the parked report above.
        (.taskFault, "Task fault: Message")
    ])
    func taskReportNoticesShowTheirExtension(_ category: Notice.Category, _ expected: String) throws {
        let tui = makeTui(); defer { tui.stop() }
        let notice = Notice(id: 1, level: .warning, message: "Message", category: category,
                            taskId: try TaskID(2), taskKind: "pi.tool", extensionName: "tools")
        tui.apply(workView(notices: [notice]))
        #expect(text(tui.notices).contains(expected))
        #expect(tui.terminalState == nil)
    }

    @Test(arguments: [DurableSessionTerminal.closed, .failed(message: "Storage failed")])
    func terminalStatusWinsOverTaskActivityAndRetainedLiveWork(_ terminal: DurableSessionTerminal) throws {
        let tui = makeTui(); defer { tui.stop() }
        // v1.5.2 D11: Terminal state wins over an ordinary blocked task too.
        let blocked = DurableBlockedTask(id: try TaskID(2), kind: "pi.tool", reason: .missingTask)
        let docs: [String: JSONObject] = ["pi.live": ["run": ["taskId": 3, "inputs": []]]]
        tui.apply(workView(docs: docs, activity: .progressing))
        #expect(tui.indicator != nil)
        let items: [Notice] = terminal == .closed ? [] : [
            .init(id: 1, level: .error, message: "Storage failed", category: .sessionFailed),
            .init(id: 2, level: .error, message: "Storage failed", category: .taskFault, taskId: blocked.id, taskKind: blocked.kind)
        ]
        tui.apply(workView(docs: docs, blocked: [blocked], activity: .progressing, notices: items, terminal: terminal))
        #expect(tui.indicator == nil)
        #expect(text(tui.status).isEmpty)
        #expect(!text(tui.editor).contains("Working"))
        if terminal == .closed { #expect(text(tui.notices).contains("Session closed")) }
        else {
            #expect(text(tui.notices).components(separatedBy: "Session failed: Storage failed").count == 2)
            #expect(text(tui.notices).contains("Task fault: Storage failed"))
        }
        tui.apply(workView(docs: docs, blocked: [blocked], activity: .progressing))
        #expect(tui.indicator == nil)
        #expect(text(tui.status).isEmpty)
    }
}
