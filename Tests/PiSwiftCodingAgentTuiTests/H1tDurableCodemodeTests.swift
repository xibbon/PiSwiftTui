import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized)
struct H1tDurableCodemodeTests {
    private let parentID = "opaque/parent:code"
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII="
    private let script = (1...12).map { "const value\($0) = \($0);" }.joined(separator: "\n")

    private func makeTui(abort: @escaping () -> Void = {}) -> DurableTui {
        DurableTui(cwd: "/tmp", handlers: DurableTuiHandlers(
            submit: { _ in }, followUp: { _ in }, abort: abort, exit: {}, selectModel: {}, cycleThinking: {}
        ), terminal: ToolTestTerminal())
    }

    private func entry(_ id: Int64, _ kind: String, _ message: JSONValue,
                       conversation: ConversationID = rootConversationID) throws -> EntryRecord {
        EntryRecord(id: try EntryID(id), conversationId: conversation, kind: kind, model: [message])
    }

    private func assistant(_ code: String = "return 7", name: String = "codemode") -> JSONValue {
        ["role": "assistant", "content": [["type": "toolCall", "id": .string(parentID),
            "name": .string(name), "arguments": ["code": .string(code)]]],
         "api": "openai-responses", "provider": "openai", "model": "test", "timestamp": 1,
         "stopReason": "toolUse", "usage": ["input": 0, "output": 0, "cacheRead": 0,
            "cacheWrite": 0, "totalTokens": 0,
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]]
    }

    private func result(_ details: CodemodeToolDetails = .init(calls: []),
                        content: [JSONValue] = [], failed: Bool = false, name: String = "codemode") throws -> JSONValue {
        ["role": "toolResult", "toolCallId": .string(parentID), "toolName": .string(name),
         "content": .array(content), "details": try JSONValue(encoding: details),
         "isError": .bool(failed), "durationMs": 4200, "timestamp": 2]
    }

    private func view(_ entries: [EntryRecord] = [], live: LiveState = LiveState(),
                      conversation: ConversationID = rootConversationID) throws -> DurableView {
        DurableView(session: .init(id: "h1t", directory: "/tmp/session", cwd: "/tmp"),
            conversation: .init(conversation: .init(id: conversation), entries: entries,
                docs: ["pi.live": try #require(JSONValue(encoding: live).objectValue)]),
            conversations: [.init(id: conversation, label: "main")], models: [])
    }

    private func parent(status: ToolSlot.Status = .running) throws -> ToolSlot {
        ToolSlot(callId: parentID, name: "codemode", taskId: try TaskID(10), status: status)
    }

    private func child(_ id: Int64, name: String, status: ToolSlot.Status = .running,
                       parentTask: Int64 = 10, parentCall: String? = nil) throws -> NestedToolSlot {
        let argument = name == "read" ? "path" : name == "bash" ? "command" : "value"
        return NestedToolSlot(callId: "unrelated:\(id)", name: name, parentCallId: parentCall ?? parentID,
            parentTaskId: try TaskID(parentTask), taskId: try TaskID(id),
            arguments: [argument: .string("argument-\(id)")], status: status)
    }

    private func text(_ component: any Component) -> String { toolTestText(component) }

    @Test func selectsRendererWithoutSourceInfoAndExpandsHighlightedJavaScript() throws {
        let tui = makeTui(); defer { tui.stop() }
        #expect(createDurableToolRenderers()["codemode"] != nil)
        #expect(withBuiltInRenderers("codemode", nil) == nil)
        tui.apply(try view([entry(1, "pi.assistant", assistant(script))]))
        #expect(tui.cards.count == 1)
        let collapsed = text(tui.chat)
        #expect(collapsed.contains("value10"))
        #expect(!collapsed.contains("value11"))
        #expect(collapsed.contains("2 more lines"))
        #expect(tui.chat.render(width: 120).joined().contains(theme.fg(.syntaxKeyword, "const")))
        tui.editor.handleInput("\u{000F}")
        #expect(tui.expanded)
        #expect(text(tui.chat).contains("value12"))
        tui.editor.handleInput("\u{000F}")
        #expect(!text(tui.chat).contains("value11"))
    }

    @Test func finalDetailsShowIDsStatusesArgumentsDurationsAndErrors() throws {
        let tui = makeTui(); defer { tui.stop() }
        let args = "{path: '" + String(repeating: "a", count: 100) + "tail'}"
        let details = CodemodeToolDetails(calls: [
            .init(id: 1, name: "read", args: args, status: .ok, durationMs: 12),
            .init(id: 2, name: "bash", args: "false", status: .error, durationMs: 1250, error: "Shell failed\nExit 1"),
            .init(id: 3, name: "models.classify", args: "judge", status: .cancelled, durationMs: 0),
            .init(id: 4, name: "models.generateImages", args: "picture", status: .running)
        ])
        tui.apply(try view([entry(1, "pi.assistant", assistant()),
            entry(2, "pi.tool-result", result(details, failed: true))]))
        let collapsed = text(tui.chat)
        for value in ["✓ #1 read", "12ms", "✗ #2 bash false 1.2s", "⊘ #3 models.classify judge 0ms",
                      "… #4 models.generateImages picture", "Took 4.2s"] {
            #expect(collapsed.contains(value))
        }
        #expect(!collapsed.contains("tail"))
        #expect(!collapsed.contains("Shell failed"))
        tui.editor.handleInput("\u{000F}")
        let expanded = text(tui.chat)
        #expect(expanded.contains("tail"))
        #expect(expanded.contains("Shell failed"))
        #expect(expanded.contains("Exit 1"))
        #expect(!expanded.contains("Model calls:"))
    }

    @Test(arguments: [false, true])
    func preservesAllOutputBlocksAfterTheStandaloneHeader(failed: Bool) throws {
        let saved = getCapabilities()
        defer { setCapabilities(saved) }
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        let tui = makeTui(); defer { tui.stop() }
        let status = failed ? "failed" : "completed"
        let content: [JSONValue] = [
            ["type": "text", "text": .string("Script \(status)\nWall time 0.1 seconds\nOutput:\n")],
            ["type": "text", "text": "First output block"],
            ["type": "text", "text": "Second output block"],
            ["type": "text", "text": "Image saved to /tmp/image-1.png"],
            ["type": "image", "data": .string(png), "mimeType": "image/png"]
        ]
        tui.apply(try view([entry(1, "pi.assistant", assistant()), entry(2, "pi.tool-result",
            result(.init(calls: [], fullOutputPath: "/tmp/full.txt"), content: content, failed: failed))]))
        for expanded in [false, true] {
            if expanded { tui.editor.handleInput("\u{000F}") }
            let output = text(tui.chat)
            for value in ["First output block", "Second output block", "Image saved to /tmp/image-1.png",
                          "image/png", "Full output: /tmp/full.txt"] { #expect(output.contains(value)) }
            #expect(!output.contains("Script \(status)"))
            #expect(!output.contains("Wall time"))
            #expect(!output.contains("Output:"))
        }
    }

    @Test func spillPathRemainsVisibleWithoutOutputAndAfterExpansion() throws {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(try view([entry(1, "pi.assistant", assistant()), entry(2, "pi.tool-result",
            result(.init(calls: [], fullOutputPath: "/tmp/empty-spill.txt")))]))
        #expect(text(tui.chat).contains("Full output: /tmp/empty-spill.txt"))
        tui.editor.handleInput("\u{000F}")
        let output = text(tui.chat)
        #expect(output.components(separatedBy: "Full output:").count == 2)
    }

    @Test func imageBlocksFollowTerminalAndCardImagePolicy() throws {
        let saved = getCapabilities()
        defer { setCapabilities(saved) }
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: false))
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(try view([entry(1, "pi.assistant", assistant()), entry(2, "pi.tool-result", result(content: [
            ["type": "text", "text": "Image saved to /tmp/picture.png"],
            ["type": "image", "data": .string(png), "mimeType": "image/png"]
        ]))]))
        let card = try #require(tui.cards.first)
        #expect(card.render(width: 120).joined().contains("\u{001B}_G"))
        #expect(text(card).contains("Image saved to /tmp/picture.png"))
        card.setShowImages(false)
        #expect(!card.render(width: 120).joined().contains("\u{001B}_G"))
        #expect(text(card).contains("image/png"))
        card.setShowImages(true)
        #expect(card.render(width: 120).joined().components(separatedBy: "\u{001B}_G").count == 2)
    }

    @Test func expansionShowsEverySavedCallAndOutputLine() throws {
        let tui = makeTui(); defer { tui.stop() }
        let details = CodemodeToolDetails(calls: (1...10).map {
            .init(id: $0, name: "saved-call-\($0)", args: "{}", status: .ok)
        })
        let content: [JSONValue] = (1...7).map { ["type": "text", "text": .string("output-line-\($0)")] }
        tui.apply(try view([entry(1, "pi.assistant", assistant()),
            entry(2, "pi.tool-result", result(details, content: content))]))
        #expect(!text(tui.chat).contains("#1 saved-call-1"))
        #expect(text(tui.chat).contains("2 earlier calls"))
        #expect(!text(tui.chat).contains("output-line-6"))
        tui.editor.handleInput("\u{000F}")
        for id in 1...10 { #expect(text(tui.chat).contains("#\(id) saved-call-\(id)")) }
        for line in 1...7 { #expect(text(tui.chat).contains("output-line-\(line)")) }
    }

    @Test func silentLiveParentShowsElapsedTimeAndPartialCalls() throws {
        let tui = makeTui(); defer { tui.stop() }
        let entries = [try entry(1, "pi.assistant", assistant())]
        var slot = try parent()
        tui.apply(try view(entries, live: LiveState(tools: [slot])))
        #expect(text(tui.chat).contains("Elapsed"))
        slot.details = try JSONValue(encoding: CodemodeToolDetails(calls: [
            .init(id: 1, name: "read", args: "input.txt", status: .running)
        ]))
        tui.apply(try view(entries, live: LiveState(tools: [slot])))
        #expect(tui.cards.count == 1)
        #expect(text(tui.chat).contains("… #1 read input.txt"))
        #expect(text(tui.chat).contains("Elapsed"))
    }

    @Test func liveReadBashAndModelChildrenUseTheOpaqueParentAndFinalRemovesThem() throws {
        let tui = makeTui(); defer { tui.stop() }
        let entries = [try entry(1, "pi.assistant", assistant())]
        var read = try child(11, name: "read", status: .done)
        read.summary = .init(isError: false, durationMs: 7)
        var bash = try child(12, name: "bash")
        bash.output = "Shell progress"
        bash.details = ["line": 3]
        bash.diagnostics = [.init(severity: .warn, message: "Check shell")]
        bash.droppedBytes = 20
        bash.droppedLines = 2
        let model = try child(13, name: "pi.codemode.models.classify", status: .pending)
        let other = try child(21, name: "other-tool", parentTask: 20, parentCall: "opaque/parent")
        let live = try LiveState(tools: [parent()], nestedTools: [model, other, bash, read])
        tui.apply(try view(entries, live: live))
        let key = DurableNestedToolParent(taskId: try TaskID(10), callId: parentID)
        #expect(tui.nestedTools.groups[key] == [read.taskId, bash.taskId, model.taskId])
        #expect(tui.nestedTools.groups.count == 2)
        let output = text(tui.nestedTools.container)
        for value in ["argument-11", "Done · 7 ms", "Shell progress", "Check shell",
                      "Output removed: 20 bytes, 2 lines", "pi.codemode.models.classify", "pending"] {
            #expect(output.contains(value))
        }
        #expect(!text(tui.chat).contains("Shell progress"))
        let final = try entry(2, "pi.tool-result", result(.init(calls: [
            .init(id: 1, name: "read", args: "input.txt", status: .ok, durationMs: 7)
        ])))
        // Keep the previous live document to check the result-first notification path.
        tui.apply(try view(entries + [final], live: live))
        #expect(Set(tui.nestedTools.cards.keys) == [other.taskId])
        #expect(tui.nestedTools.groups[key] == nil)
        #expect(tui.cards.count == 1)
        #expect(text(tui.chat).contains("✓ #1 read"))
        #expect(!text(tui.chat).contains("Elapsed"))
        tui.apply(try view(entries + [final]))
        #expect(tui.nestedTools.cards.isEmpty)
    }

    @Test func parentTaskAndCallIDsBothSelectLiveGroupsAndSettlement() throws {
        let tui = makeTui(); defer { tui.stop() }
        let first = try child(11, name: "read")
        let second = try child(21, name: "bash", parentTask: 20)
        let third = try child(12, name: "model", parentCall: "different/opaque")
        tui.apply(try view(live: LiveState(nestedTools: [first, second, third])))
        #expect(tui.nestedTools.groups.count == 3)
        tui.apply(try view(live: LiveState(tools: [parent(status: .done)], nestedTools: [first, second, third])))
        #expect(Set(tui.nestedTools.cards.keys) == [second.taskId, third.taskId])
    }

    @Test func savedParentResultRemovesOnlyItsTaskWhenCallIDsAreEqual() throws {
        let tui = makeTui(); defer { tui.stop() }
        let entries = [try entry(1, "pi.assistant", assistant())]
        let first = try child(11, name: "read")
        let second = try child(21, name: "bash", parentTask: 20)
        let live = try LiveState(tools: [parent()], nestedTools: [first, second])
        tui.apply(try view(entries, live: live))
        tui.apply(try view(entries + [entry(2, "pi.tool-result", result())], live: live))
        #expect(Set(tui.nestedTools.cards.keys) == [second.taskId])
    }

    @Test func continueRebuildsSavedAndLiveViewsWithoutDuplicateRows() throws {
        let entries = [try entry(1, "pi.assistant", assistant(script))]
        let child = try child(11, name: "read")
        let live = try LiveState(tools: [parent()], nestedTools: [child])
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(try view(entries, live: live))
        tui.apply(try view(entries, live: live))
        #expect(tui.cards.count == 1)
        #expect(tui.nestedTools.cards.count == 1)
        let finalEntries = entries + [try entry(2, "pi.tool-result", result(.init(calls: [
            .init(id: 1, name: "read", args: "input.txt", status: .ok, durationMs: 10)
        ]), content: [["type": "text", "text": "Saved return value"]]))]
        tui.apply(try view(finalEntries))
        let reopened = makeTui(); defer { reopened.stop() }
        let saved = try view(finalEntries)
        reopened.apply(saved)
        let output = text(reopened.chat)
        reopened.apply(saved)
        #expect(text(reopened.chat) == output)
        #expect(output == text(tui.chat))
        #expect(reopened.cards.count == 1)
        #expect(reopened.nestedTools.cards.isEmpty)
        #expect(output.components(separatedBy: "✓ #1 read").count == 2)
        #expect(output.components(separatedBy: "Saved return value").count == 2)
        #expect(output.contains("Took 4.2s"))
        #expect(!output.contains("Elapsed"))
    }

    @Test func liveCardBeforeSavedAssistantIsReused() throws {
        let tui = makeTui(); defer { tui.stop() }
        let live = try LiveState(tools: [parent()])
        tui.apply(try view(live: live))
        let card = try #require(tui.cards.first)
        tui.apply(try view([entry(1, "pi.assistant", assistant())], live: live))
        #expect(tui.cards.count == 1)
        #expect(tui.cards.first === card)
        #expect(text(tui.chat).contains("return 7"))
    }

    @Test func rendererTimerStopsOnFinalAndStateRelease() throws {
        let renderers = createDurableCodemodeRenderers()
        var context: ToolRenderContext? = ToolRenderContext(executionStarted: true)
        let call = try #require(renderers.renderCall)
        let render = try #require(renderers.renderResult)
        _ = try call(["code": AnyCodable("return 7")], theme, #require(context))
        _ = try render(.init(content: []), .init(expanded: false, isPartial: true), theme, #require(context))
        let pendingTimer = toolTimerState(try #require(context)).timer
        let timer = try #require(pendingTimer)
        _ = try render(.init(content: []), .init(expanded: false, isPartial: false), theme, #require(context))
        #expect(timer.isCancelled)
        #expect(toolTimerState(try #require(context)).timer == nil)
        context = ToolRenderContext(executionStarted: true)
        _ = try call(["code": AnyCodable("return 7")], theme, #require(context))
        _ = try render(.init(content: []), .init(expanded: false, isPartial: true), theme, #require(context))
        let pendingReleasedTimer = toolTimerState(try #require(context)).timer
        let releasedTimer = try #require(pendingReleasedTimer)
        weak let state = toolTimerState(try #require(context))
        context = nil
        #expect(state == nil)
        #expect(releasedTimer.isCancelled)
    }

    @Test func viewChangeAndStopFinishTimersAndKeepExpansionAndAbortPaths() throws {
        var aborts = 0
        let tui = makeTui(abort: { aborts += 1 }); defer { tui.stop() }
        let entries = [try entry(1, "pi.assistant", assistant(script))]
        tui.apply(try view(entries, live: LiveState(tools: [parent()], nestedTools: [child(11, name: "bash")])))
        let oldCard = try #require(tui.cards.first)
        #expect(text(oldCard).contains("Elapsed"))
        tui.editor.handleInput("\u{001B}")
        #expect(aborts == 1)
        tui.editor.handleInput("\u{000F}")
        let otherID = try ConversationID(2)
        // Equal entry IDs in another conversation still require a rebuild.
        tui.apply(try view([entry(1, "pi.assistant", assistant(script), conversation: otherID)], conversation: otherID))
        #expect(text(oldCard).contains("Took"))
        #expect(!text(oldCard).contains("Elapsed"))
        #expect(tui.cards.first !== oldCard)
        #expect(tui.nestedTools.cards.isEmpty)
        #expect(tui.expanded)
        #expect(text(tui.chat).contains("value12"))
        tui.apply(try view([entry(1, "pi.assistant", assistant(script), conversation: otherID)],
            live: LiveState(tools: [parent()]), conversation: otherID))
        let running = try #require(tui.cards.first)
        #expect(text(running).contains("Elapsed"))
        tui.stop()
        #expect(tui.cards.isEmpty)
        #expect(tui.tools.isEmpty)
        #expect(tui.nestedTools.cards.isEmpty)
        #expect(text(running).contains("Took"))
        #expect(!text(running).contains("Elapsed"))
    }

    @Test func toolSearchKeepsNormalTextOutput() throws {
        let tui = makeTui(); defer { tui.stop() }
        tui.apply(try view([entry(1, "pi.assistant", assistant(name: "tool_search")),
            entry(2, "pi.tool-result", result(content: [["type": "text", "text": "Loaded bash: Run a shell command"]],
                name: "tool_search"))]))
        #expect(text(tui.chat).contains("Loaded bash: Run a shell command"))
    }
}
