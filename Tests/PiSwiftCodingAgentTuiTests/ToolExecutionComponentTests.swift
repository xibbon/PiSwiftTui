import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

final class ToolTestTerminal: Terminal {
    var columns = 120
    var rows = 40
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

func toolTestPlain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\][^\u{0007}]*\u{0007}", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
}

@MainActor func toolTestText(_ component: Component, width: Int = 120) -> String {
    component.render(width: width).map { toolTestPlain($0).replacingOccurrences(of: " +$", with: "", options: .regularExpression) }.joined(separator: "\n")
}

func toolTestDefinition(_ name: String = "custom_tool") -> CustomTool {
    CustomTool(name: name, label: name, description: "Test tool", parameters: [:], execute: { _, _, _, _, _ in
        AgentToolResult(content: [], details: nil)
    })
}

func toolTestResult(_ text: String, tool: String = "read", details: [String: Any]? = nil, isError: Bool = false) -> ToolResultMessage {
    ToolResultMessage(toolCallId: "test-call", toolName: tool, content: text.isEmpty ? [] : [.text(TextContent(text: text))], details: details.map(AnyCodable.init), isError: isError)
}

@MainActor @Suite(.serialized) struct ToolExecutionComponentTests {
    private func component(_ name: String = "read", args: [String: AnyCodable] = [:], definition: CustomTool? = nil, renderers: ToolRenderers? = nil, cwd: String = FileManager.default.currentDirectoryPath) -> ToolExecutionComponent {
        ToolExecutionComponent(toolName: name, toolCallId: "test-call", args: args, customTool: definition, renderers: renderers, ui: TUI(terminal: ToolTestTerminal()), cwd: cwd)
    }

    @Test func customCallAndResultStack() {
        var definition = toolTestDefinition()
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("custom call", paddingX: 0, paddingY: 0) } }
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("custom result", paddingX: 0, paddingY: 0) } }
        let row = component("custom_tool", definition: definition)
        #expect(toolTestText(row).contains("custom call"))
        row.updateResult(toolTestResult("done"))
        #expect(toolTestText(row).contains("custom call"))
        #expect(toolTestText(row).contains("custom result"))
    }

    @Test func emptySelfRenderedRowsHaveNoSpace() {
        var definition = toolTestDefinition()
        definition.renderShell = .self
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("", paddingX: 0, paddingY: 0) } }
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("", paddingX: 0, paddingY: 0) } }
        let row = component("custom_tool", definition: definition)
        #expect(row.render(width: 120).isEmpty)
        row.updateResult(toolTestResult(""))
        #expect(row.render(width: 120).isEmpty)
    }

    @Test func builtInOverrideInheritsRendering() {
        let row = component("edit", args: ["path": AnyCodable("README.md"), "oldText": AnyCodable("before"), "newText": AnyCodable("after")], definition: toolTestDefinition("edit"))
        row.updateResult(toolTestResult("", tool: "edit", details: ["diff": "+1 after", "firstChangedLine": 1]))
        let output = toolTestText(row)
        #expect(output.contains("edit"))
        #expect(output.contains("README.md"))
        #expect(!output.contains(":1"))
    }

    @Test func legacyFilePathIsRendered() {
        let row = component(args: ["file_path": AnyCodable("README.md")])
        #expect(toolTestText(row).contains("read"))
        #expect(toolTestText(row).contains("README.md"))
    }

    // PiSwift does not emit upstream's initial empty bash update. The TUI starts its clock from the execution event.
    @Test func bashExecutionStartsBeforeOutputArrives() {
        let row = component("bash", args: ["command": AnyCodable("sleep 10")])
        row.markExecutionStarted()
        row.updateResult(toolTestResult("", tool: "bash"), isPartial: true)
        #expect(toolTestText(row).contains("Elapsed"))
        row.updateResult(toolTestResult("", tool: "bash"))
        #expect(toolTestText(row).contains("Took"))
    }

    @Test func bashFinalFullOutputDetailsAppearOnce() {
        let row = component("bash", args: ["command": AnyCodable("generate output")])
        let output = (2001...4000).map { String(format: "line-%04d", $0) }.joined(separator: "\n")
        let footer = "\n\n[Showing lines 2001-4000 of 4000. Full output: /tmp/test-output.log]"
        row.setExpanded(true)
        row.updateResult(toolTestResult(output + footer, tool: "bash", details: ["fullOutputPath": "/tmp/test-output.log", "truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 2000, "totalLines": 4000]]))
        let rendered = toolTestText(row, width: 200)
        #expect(rendered.components(separatedBy: "Full output:").count - 1 == 1)
        #expect(rendered.contains("Truncated: showing 2000 of 4000 lines"))
        #expect(!rendered.contains("[Showing lines 2001-4000"))
        #expect(rendered.range(of: "line-4000[^\\n]*\\n[^\\S\\n]*\\n \\[Full output:", options: .regularExpression) != nil)
        #expect(rendered.range(of: "line-4000[^\\n]*\\n[^\\S\\n]*\\n[^\\S\\n]*\\n \\[Full output:", options: .regularExpression) == nil)
    }

    @Test func activeBuiltInDefinitionDoesNotDuplicateHeader() {
        let row = component(args: ["path": AnyCodable("notes.txt")], definition: toolTestDefinition("read"))
        row.updateResult(toolTestResult("hello"))
        #expect(toolTestText(row).components(separatedBy: "read").count - 1 == 1)
    }

    @Test func missingResultSlotUsesBuiltIn() {
        var definition = toolTestDefinition("read")
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("override call", paddingX: 0, paddingY: 0) } }
        let row = component(args: ["path": AnyCodable("notes.txt")], definition: definition)
        row.updateResult(toolTestResult("hello"))
        row.setExpanded(true)
        #expect(toolTestText(row).contains("override call"))
        #expect(toolTestText(row).contains("hello"))
    }

    @Test func missingCallSlotUsesBuiltIn() {
        var definition = toolTestDefinition("read")
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("override result", paddingX: 0, paddingY: 0) } }
        let row = component(args: ["path": AnyCodable("README.md")], definition: definition)
        row.updateResult(toolTestResult("hello"))
        #expect(toolTestText(row).contains("README.md"))
        #expect(toolTestText(row).contains("override result"))
    }

    @Test func customSlotsWinWithBuiltInParameters() {
        var definition = toolTestDefinition("read")
        definition.parameters = createReadTool(cwd: FileManager.default.currentDirectoryPath).parameters
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("override call", paddingX: 0, paddingY: 0) } }
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("override result", paddingX: 0, paddingY: 0) } }
        let row = component(args: ["path": AnyCodable("README.md")], definition: definition)
        row.updateResult(toolTestResult("hello"))
        #expect(toolTestText(row).contains("override call"))
        #expect(toolTestText(row).contains("override result"))
        #expect(!toolTestText(row).contains("read README.md"))
    }

    @Test func customSlotsWinAfterRegistryAdaptation() {
        var definition = toolTestDefinition("read")
        definition.parameters = createReadTool(cwd: FileManager.default.currentDirectoryPath).parameters
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("wrapped override call", paddingX: 0, paddingY: 0) } }
        definition.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("wrapped override result", paddingX: 0, paddingY: 0) } }
        let row = component(args: ["path": AnyCodable("README.md")], renderers: withBuiltInRenderers("read", definition))
        row.updateResult(toolTestResult("hello"))
        #expect(toolTestText(row).contains("wrapped override call"))
        #expect(toolTestText(row).contains("wrapped override result"))
    }

    @Test func callAndResultShareRendererState() {
        var renderers = ToolRenderers()
        renderers.renderCall = { _, _, context in
            context.state.values["token"] = "shared-token"
            return Text("custom call shared-token", paddingX: 0, paddingY: 0)
        }
        renderers.renderResult = { _, _, _, context in
            Text("custom result \(context.state.values["token"] as? String ?? "missing")", paddingX: 0, paddingY: 0)
        }
        let row = component("custom_tool", renderers: renderers)
        row.updateResult(toolTestResult("done"))
        #expect(toolTestText(row).contains("custom call shared-token"))
        #expect(toolTestText(row).contains("custom result shared-token"))
    }

    @Test func resultContextContainsArgumentsAndCallId() {
        var renderers = ToolRenderers()
        renderers.renderResult = { _, _, _, context in
            Text("arg:\(context.args["foo"]?.value as? String ?? "missing") id:\(context.toolCallId)", paddingX: 0, paddingY: 0)
        }
        let row = component("custom_tool", args: ["foo": AnyCodable("bar")], renderers: renderers)
        row.updateResult(toolTestResult("done"))
        #expect(toolTestText(row).contains("arg:bar id:test-call"))
    }

    @Test func fallbackResultsCollapseUntilExpanded() {
        let row = component("custom_tool", definition: toolTestDefinition())
        row.updateResult(toolTestResult((1...15).map { "line-\($0)" }.joined(separator: "\n")))
        let collapsed = toolTestText(row)
        #expect(collapsed.contains("line-10"))
        #expect(!collapsed.contains("line-11"))
        #expect(collapsed.contains("5 more lines"))
        #expect(collapsed.contains("to expand"))
        row.setExpanded(true)
        #expect(toolTestText(row).contains("line-15"))
        #expect(!toolTestText(row).contains("more lines"))
    }

    @Test func writePreviewTrimsTrailingBlankLines() {
        let row = component("write", args: ["path": AnyCodable("notes.txt"), "content": AnyCodable("one\ntwo\n\n")])
        let lines = row.render(width: 120).map(toolTestPlain).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("one"))
        #expect(lines.contains("two"))
        #expect(lines.suffix(from: lines.firstIndex(of: "two")! + 1).count == 1)
    }

    @Test func readResultTrimsTrailingBlankLines() {
        let row = component(args: ["path": AnyCodable("notes.txt")])
        row.updateResult(toolTestResult("one\ntwo\n\n"))
        row.setExpanded(true)
        let lines = row.render(width: 120).map(toolTestPlain).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("one"))
        #expect(lines.contains("two"))
        #expect(lines.suffix(from: lines.firstIndex(of: "two")! + 1).count == 1)
    }

    @Test func readErrorsDoNotUseSyntaxHighlighting() {
        let row = component(args: ["path": AnyCodable("config.swift"), "offset": AnyCodable(120), "limit": AnyCodable(130)])
        let error = "Offset 120 is beyond end of file (96 lines total)"
        row.updateResult(toolTestResult(error, isError: true))
        #expect(toolTestText(row).contains(error))
        #expect(row.render(width: 120).joined(separator: "\n").contains(theme.fg(.toolOutput, error)))
    }

    @Test func clickExpandsReadResult() throws {
        let row = component(args: ["path": AnyCodable("notes.txt")])
        row.updateResult(toolTestResult("hidden content"))
        let lines = row.render(width: 120)
        let y = try #require(lines.firstIndex { toolTestPlain($0).contains("notes.txt") })
        let event = TuiMouseEvent(type: .click, button: .left, x: 2, y: y, screenX: 2, screenY: y, width: 120, height: lines.count)
        #expect(row.handleMouse(event)?.handled == true)
        #expect(toolTestText(row).contains("hidden content"))
    }

    @Test func ordinaryReadResultIsHiddenUntilExpanded() {
        let row = component(args: ["path": AnyCodable("notes.txt")])
        row.updateResult(toolTestResult("hidden content"))
        #expect(!toolTestText(row).contains("hidden content"))
        row.setExpanded(true)
        #expect(toolTestText(row).contains("hidden content"))
    }

    @Test func specialReadClassificationsHideResult() {
        let cwd = "/tmp/pi-render-tests"
        let cases = [(cwd + "/attio/SKILL.md", "[skill] attio"), (cwd + "/.pi/AGENTS.md", "read resource .pi/AGENTS.md"), (cwd + "/.pi/AGENTS.override.md", "read resource .pi/AGENTS.override.md"), ("/tmp/AGENTS.md", "read resource /tmp/AGENTS.md"), (getReadmePath(), "read docs README.md")]
        for (path, expected) in cases {
            let row = component(args: ["path": AnyCodable(path)], cwd: cwd)
            row.updateResult(toolTestResult("hidden instructions"))
            #expect(toolTestText(row).contains(expected))
            #expect(!toolTestText(row).contains("hidden instructions"))
            row.setExpanded(true)
            #expect(toolTestText(row).contains("hidden instructions"))
        }
    }

    @Test func compactReadLineRangePrecedesHint() throws {
        for (path, label) in [("/tmp/attio/SKILL.md", "[skill] attio:120-329"), (getReadmePath(), "read docs README.md:120-329")] {
            let row = component(args: ["path": AnyCodable(path), "offset": AnyCodable(120), "limit": AnyCodable(210)])
            let output = toolTestText(row)
            #expect(output.contains(label))
            let range = try #require(output.range(of: ":120-329"))
            let hint = try #require(output.range(of: "to expand"))
            #expect(range.lowerBound < hint.lowerBound)
        }
    }


    @Test func selfRenderedClickUsesLeadingBlankLineOffset() throws {
        var renderers = ToolRenderers(renderShell: .self)
        renderers.renderCall = { _, _, _ in Text("self header", paddingX: 0, paddingY: 0) }
        renderers.renderResult = { _, options, _, _ in Text(options.expanded ? "expanded result" : "collapsed result", paddingX: 0, paddingY: 0) }
        let row = component("custom_tool", renderers: renderers)
        row.updateResult(toolTestResult("body"))
        let lines = row.render(width: 120)
        #expect(toolTestPlain(lines[0]).isEmpty)
        let y = try #require(lines.firstIndex { toolTestPlain($0).contains("self header") })
        #expect(y == 1)
        let event = TuiMouseEvent(type: .click, button: .left, x: 0, y: y, screenX: 0, screenY: y, width: 120, height: lines.count)
        #expect(row.handleMouse(event)?.handled == true)
        #expect(toolTestText(row).contains("expanded result"))
    }

    @Test func unsupportedImageFallbackAppearsOnceAfterUpdates() {
        let saved = getCapabilities()
        defer { setCapabilities(saved) }
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        let row = component("unknown")
        let image = ImageContent(data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=", mimeType: "image/png")
        row.updateResult(ToolResultMessage(toolCallId: "test-call", toolName: "unknown", content: [.image(image)], isError: false))
        for show in [false, true, false, true] {
            row.setShowImages(show)
            row.setImageWidthCells(0)
            row.setImageWidthCells(100)
            #expect(toolTestText(row).components(separatedBy: "image/png").count - 1 == 1)
        }
    }

    @Test func contextTracksLifecycleFlagsAndRequestsInvalidate() {
        var seen: ToolRenderContext?
        var renders = 0
        var renderers = ToolRenderers()
        renderers.renderCall = { _, _, context in
            seen = context
            renders += 1
            return Text("call", paddingX: 0, paddingY: 0)
        }
        let row = component("custom_tool", renderers: renderers)
        #expect(seen?.executionStarted == false)
        #expect(seen?.argsComplete == false)
        row.markExecutionStarted()
        row.setArgsComplete()
        row.setExpanded(true)
        row.setShowImages(false)
        row.updateResult(toolTestResult("failed", isError: true))
        #expect(seen?.executionStarted == true)
        #expect(seen?.argsComplete == true)
        #expect(seen?.expanded == true)
        #expect(seen?.showImages == false)
        #expect(seen?.isError == true)
        #expect(seen?.isPartial == false)
        let count = renders
        seen?.invalidate()
        #expect(renders > count)
    }

    @Test func rendererThrowsUseCallAndResultFallbacks() {
        enum Failure: Error { case renderer }
        var renderers = ToolRenderers()
        renderers.renderCall = { _, _, _ in throw Failure.renderer }
        renderers.renderResult = { _, _, _, _ in throw Failure.renderer }
        let row = component("failing", renderers: renderers)
        row.updateResult(toolTestResult((1...15).map { "line-\($0)" }.joined(separator: "\n")))
        #expect(toolTestText(row).contains("failing"))
        #expect(toolTestText(row).contains("line-10"))
        #expect(!toolTestText(row).contains("line-11"))
        #expect(toolTestText(row).contains("5 more lines"))
    }

    @Test func rendererSlotsReceiveTheirPreviousComponents() {
        var call: Component?
        var result: Component?
        var reusedCall = false
        var reusedResult = false
        var renderers = ToolRenderers()
        renderers.renderCall = { _, _, context in
            if let previous = context.lastComponent { reusedCall = previous === call }
            let text = (context.lastComponent as? Text) ?? Text("call", paddingX: 0, paddingY: 0)
            call = text
            return text
        }
        renderers.renderResult = { _, _, _, context in
            if let previous = context.lastComponent { reusedResult = previous === result }
            let text = (context.lastComponent as? Text) ?? Text("result", paddingX: 0, paddingY: 0)
            result = text
            return text
        }
        let row = component("custom_tool", renderers: renderers)
        row.updateResult(toolTestResult("one"), isPartial: true)
        row.updateResult(toolTestResult("two"))
        #expect(reusedCall)
        #expect(reusedResult)
    }
}
