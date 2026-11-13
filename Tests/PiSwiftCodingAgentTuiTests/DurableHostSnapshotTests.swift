import MiniTui
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DurableHostSnapshotTests {
    private func tui() -> DurableTui {
        DurableTui(cwd: "/tmp", handlers: DurableTuiHandlers(
            submit: { _ in }, followUp: { _ in }, abort: {}, exit: {}, selectModel: {}, cycleThinking: {}
        ), terminal: ToolTestTerminal())
    }

    private func snapshot(items: [TranscriptItem] = [], docs: [String: JSONObject] = [:],
                          notices: [Notice] = [], mode: DurableOpenMode = .write,
                          activity: DurableActivity = .idle,
                          conversation: ConversationRecord = .init(id: rootConversationID)) -> DurableHostView {
        let legacy = DurableView(session: .init(id: "host", directory: "/tmp/host", cwd: "/tmp"),
            conversation: .init(conversation: conversation, entries: [], docs: docs),
            conversations: [.init(id: rootConversationID, label: "main"),
                            .init(id: conversation.id, label: "shown")], models: [], notices: notices,
            activity: activity)
        return DurableHostView(legacy: legacy,
            transcript: .init(conversation: conversation, docs: docs, items: items), mode: mode)
    }

    @Test func forkSwitchUsesConversationRowIdentity() throws {
        let tui = tui(); defer { tui.stop() }
        let root = EntryRecord(id: try EntryID(3), conversationId: rootConversationID,
            kind: "app.note", data: "Root row")
        tui.apply(snapshot(items: [.entry(root)]))
        #expect(toolTestText(tui.chat).contains("Root row"))
        let childID = try ConversationID(9)
        let child = ConversationRecord(id: childID,
            parent: .init(conversationId: rootConversationID, at: root.id))
        let forked = EntryRecord(id: try EntryID(4), conversationId: childID,
            kind: "app.note", data: "Fork row")
        tui.apply(snapshot(items: [.entry(forked)], conversation: child))
        #expect(toolTestText(tui.chat).contains("Fork row"))
        #expect(!toolTestText(tui.chat).contains("Root row"))
        #expect(tui.chat.children.count == 2)
        tui.apply(snapshot(items: [.entry(root)]))
        #expect(toolTestText(tui.chat).contains("Root row"))
        #expect(!toolTestText(tui.chat).contains("Fork row"))
    }

    @Test func pageMarkersAndStableRowsDoNotDuplicateOnUpdate() throws {
        let tui = tui(); defer { tui.stop() }
        let entry = EntryRecord(id: try EntryID(8), conversationId: rootConversationID,
            kind: "app.note", data: "Saved row")
        let gap = TranscriptGap(after: try EntryID(3), upTo: try EntryID(8))
        let first = snapshot(items: [.earlier, .gap(gap), .entry(entry)])
        tui.apply(first)
        let components = tui.chat.children
        #expect(first.rows.count == 3)
        #expect(Set(first.rows.map(\.id)).count == 3)
        // The live content container follows the transcript rows.
        #expect(components.count == first.rows.count + 1)
        #expect(toolTestText(tui.chat).contains("Earlier entries available"))
        #expect(toolTestText(tui.chat).contains("Entries in this range not loaded"))
        tui.apply(first)
        #expect(tui.chat.children.count == first.rows.count + 1)
        #expect(zip(components, tui.chat.children).allSatisfy { $0 === $1 })
        let earlier = EntryRecord(id: try EntryID(2), conversationId: rootConversationID,
            kind: "app.note", data: "Older row")
        let second = snapshot(items: [.entry(earlier), .gap(gap), .entry(entry)])
        tui.apply(second)
        #expect(second.rows.last?.id == first.rows.last?.id)
        #expect(tui.chat.children.count == second.rows.count + 1)
        #expect(tui.chat.children[2] === components[2])
        #expect(!toolTestText(tui.chat).contains("Earlier entries available"))
    }

    @Test func fiveHundredEntriesLoadByPageAndKeepRowsDuringLiveUpdates() throws {
        let tui = tui(); defer { tui.stop() }
        let entries = try (1...500).map { number in
            EntryRecord(id: try EntryID(Int64(number)), conversationId: rootConversationID,
                kind: "app.note", data: .string("Saved entry \(number)"))
        }
        func page(_ start: Int, docs: [String: JSONObject] = [:]) -> DurableHostView {
            snapshot(items: [.earlier] + entries[(start - 1)...].map(TranscriptItem.entry), docs: docs)
        }
        tui.apply(page(451))
        #expect(tui.rowConstructionCount == 51)
        #expect(toolTestText(tui.chat).contains("Saved entry 500"))
        #expect(!toolTestText(tui.chat).contains("Saved entry 450"))
        for (start, count) in [(401, 101), (351, 151), (301, 201)] {
            let held = Array(tui.chat.children.dropLast())
            tui.apply(page(start))
            #expect(tui.rowConstructionCount == count)
            #expect(tui.chat.children.count == count + 1)
            #expect(tui.chat.children[0] === held[0])
            #expect(tui.chat.children[51] === held[1])
        }
        let held = Array(tui.chat.children.dropLast())
        tui.apply(page(301, docs: ["pi.live": ["tools": [
            ["callId": "live", "name": "read", "status": "running", "output": "Live output"]
        ]]]))
        #expect(tui.rowConstructionCount == 201)
        #expect(zip(held, tui.chat.children.dropLast()).allSatisfy { $0 === $1 })
        #expect(tui.tools["live"] != nil)

        let gap = TranscriptGap(after: try EntryID(400), upTo: try EntryID(451))
        let missing = snapshot(items: [.earlier] + entries[300..<400].map(TranscriptItem.entry)
            + [.gap(gap)] + entries[450...].map(TranscriptItem.entry))
        tui.apply(missing)
        #expect(toolTestText(tui.chat).contains("Entries in this range not loaded"))
        let lastRow = tui.chat.children[tui.chat.children.count - 2]
        let beforeFill = tui.rowConstructionCount
        tui.apply(page(301))
        #expect(tui.rowConstructionCount == beforeFill + 50)
        #expect(tui.chat.children[tui.chat.children.count - 2] === lastRow)
        #expect(!toolTestText(tui.chat).contains("Entries in this range not loaded"))
        #expect(toolTestText(tui.chat).contains("Saved entry 425"))
    }

    @Test func afterRunChildrenKeepTheSessionBusy() throws {
        let tui = tui(); defer { tui.stop() }
        let view = snapshot(docs: ["pi.live": [
            "run": ["taskId": 2, "inputs": [], "turns": 3, "afterRun": ["tasks": [4, 5]]]
        ]], activity: .progressing)
        tui.apply(view)
        let indicator = try #require(tui.indicator)
        #expect(toolTestText(indicator).contains("Finishing 2 after-run tasks"))
        #expect(toolTestText(tui.status).contains("Turn 3"))
    }

    @Test(arguments: [RunFailureReason.modelError, .noModel, .aborted, .reset, .faulted,
                      .orphaned, .interrupted, .restartLimit, .nothingToAnswer, .turnLimit])
    func allEndingsShowHostText(_ reason: RunFailureReason) throws {
        let tui = tui(); defer { tui.stop() }
        let failure = RunFailure(taskId: try TaskID(2), inputs: [], reason: reason, detail: "Saved diagnostic")
        let document = try #require(JSONValue(encoding: failure).objectValue)
        let view = snapshot(docs: ["pi.live": ["runFailure": .object(document)]])
        let ending = try #require(view.ending)
        tui.apply(view)
        let card = try #require(tui.notices.children.first as? Box)
        #expect(toolTestText(card.children[0]) == ending.text)
        #expect(toolTestText(card.children[1]) == ending.explanation)
        #expect(toolTestText(card.children[2]) == ending.detail)
        #expect(toolTestText(card.children[3]) == ending.action)
        let text = toolTestText(tui.notices, width: 200)
        #expect(text.contains(ending.text))
        #expect(text.contains(ending.explanation))
        #expect(text.contains(ending.action))
        #expect(text.contains("Saved diagnostic"))
        #expect(!text.contains("/retry"))
    }

    @Test func allCurrentReportKindsShowTheirLabelsAndIdentity() throws {
        let tui = tui(); defer { tui.stop() }
        let task = ReportTask(id: try TaskID(7), kind: "app.task", conversationId: rootConversationID)
        let reports: [ReportInfo] = [.storageFailed,
            .taskInterrupted(task: task, reason: .restartLimit, restarts: 3),
            .taskFaulted(task: task, reason: .threw), .migrationFailed(task: task),
            .taskError(task: task), .taskOutdated(task: task, reason: .missingTask),
            .extensionError(extension: "sample", task: task), .hostError(callback: .settings, task: task),
            .listenerError]
        let labels = ["Storage failed", "Task interrupted", "Task failed", "Migration failed",
                      "Task error", "Task definition unavailable", "Extension error", "Host callback failed", "Listener failed"]
        for (index, info) in reports.enumerated() {
            let notice = Notice(id: index, level: .error, message: "Saved report", category: .report,
                taskId: task.id, taskKind: task.kind, reportInfo: info)
            tui.apply(snapshot(notices: [notice]))
            let text = toolTestText(tui.notices)
            #expect(text.contains(labels[index]))
            #expect(text.contains("#7"))
            #expect(text.contains("app.task"))
            #expect(text.contains("Saved report"))
        }
    }

    @Test func readOnlySnapshotShowsRefreshAction() {
        let tui = tui(); defer { tui.stop() }
        tui.apply(snapshot(mode: .readOnly))
        #expect(toolTestText(tui.status).contains("Read-only"))
        #expect(toolTestText(tui.status).contains("/refresh"))
        tui.apply(snapshot())
        #expect(!toolTestText(tui.status).contains("Read-only"))
    }

    @Test func busyContinueRejectionShowsHostText() {
        let tui = tui(); defer { tui.stop() }
        let message = String(describing: ConversationBusy(conversationId: rootConversationID))
        tui.apply(snapshot(notices: [.init(id: 1, level: .error, message: message)]))
        #expect(toolTestText(tui.notices).contains(message))
    }
}
