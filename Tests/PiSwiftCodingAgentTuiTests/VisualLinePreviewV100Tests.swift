import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// pi-mono v1.0.0: visual-truncate.ts, bash.ts, codemode/renderer.ts,
// mcp/tools.ts, and the added codemode-renderer.test.ts wrapped-line case.
@MainActor @Suite(.serialized) struct VisualLinePreviewV100Tests {
    @Test func truncateKeepsStartOrEndWrappedLines() {
        let text = "abcdefghij"
        let start = truncateToVisualLines(text, maxVisualLines: 2, width: 2, keep: .start)
        let end = truncateToVisualLines(text, maxVisualLines: 2, width: 2)
        #expect(start.visualLines.map(toolTestPlain) == ["ab", "cd"])
        #expect(end.visualLines.map(toolTestPlain) == ["gh", "ij"])
        #expect(start.skippedCount == 3)
        #expect(end.skippedCount == 3)
        #expect(truncateToVisualLines("", maxVisualLines: 2, width: 2, keep: .start).visualLines.isEmpty)
    }

    @Test func previewPlacesHintBesideRetainedLinesAndCutsHintToWidth() {
        let text = "first\nsecond\nthird"
        let start = VisualLinePreview(text: text, maxVisualLines: 1, keep: .start) { "\($0) hidden lines" }
        let end = VisualLinePreview(text: text, maxVisualLines: 1, keep: .end) { "\($0) hidden lines" }
        #expect(plainLines(start, width: 8) == ["first", "2 hid..."])
        #expect(plainLines(end, width: 8) == ["2 hid...", "third"])
        #expect(start.render(width: 8).allSatisfy { visibleWidth($0) <= 8 })
        let short = VisualLinePreview(text: "short", maxVisualLines: 5, keep: .start) { _ in "unused" }
        #expect(plainLines(short, width: 8) == ["short"])
    }

    @Test func previewCachesAtCurrentWidthAndClearsCacheOnInvalidation() {
        var hiddenCounts: [Int] = []
        let preview = VisualLinePreview(text: String(repeating: "x", count: 40), maxVisualLines: 1, keep: .start) {
            hiddenCounts.append($0)
            return "\($0) hidden"
        }
        let first = preview.render(width: 10)
        #expect(preview.render(width: 10) == first)
        #expect(hiddenCounts == [3])
        _ = preview.render(width: 20)
        #expect(hiddenCounts == [3, 1])
        preview.invalidate()
        _ = preview.render(width: 20)
        #expect(hiddenCounts == [3, 1, 1])
    }

    @Test func codemodeCollapsedOutputLimitsWrappedLines() throws {
        // Port of the added v1.0.0 codemode-renderer.test.ts test.
        let result = AgentToolResult(content: [
            .text(TextContent(text: "Script completed\nWall time 0.1 seconds\nOutput:\n")),
            .text(TextContent(text: String(repeating: "x", count: 1000))),
        ], details: AnyCodable(["calls": [], "fullOutputPath": "/tmp/out.txt"]))
        let render = try #require(createCodemodeRenderers().renderResult)
        let component = try render(result, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext(showImages: false))
        let lines = plainLines(component, width: 50).dropFirst()
        #expect(lines.count == 7)
        #expect(Array(lines.prefix(5)) == Array(repeating: String(repeating: "x", count: 50), count: 5))
        #expect(lines.dropFirst(5).first?.hasPrefix("... (15 more lines,") == true)
        #expect(lines.last == "Full output: /tmp/out.txt")
    }

    @Test func codemodeScriptLimitsWrappedLinesAndReusesContainer() throws {
        let render = try #require(createCodemodeRenderers().renderCall)
        let args = ["code": AnyCodable(String(repeating: "x", count: 1000))]
        let component = try render(args, theme, ToolRenderContext())
        let lines = plainLines(component, width: 50)
        #expect(lines.count == 12)
        #expect(lines.first == "codemode")
        #expect(Array(lines.dropFirst().prefix(10)) == Array(repeating: String(repeating: "x", count: 50), count: 10))
        #expect(lines.last?.hasPrefix("... (10 more lines,") == true)
        let expanded = try render(args, theme, ToolRenderContext(lastComponent: component, expanded: true))
        #expect(expanded === component)
        #expect(plainLines(expanded, width: 50).count == 21)
        let invalid = try render(["code": AnyCodable(1)], theme, ToolRenderContext(lastComponent: component))
        #expect(invalid === component)
        #expect(plainLines(invalid, width: 50) == ["codemode [invalid arg]"])
    }

    @Test func mcpCollapsedOutputLimitsWrappedLinesAndShowsFullPath() throws {
        let render = try #require(createMcpRenderers(label: "server/tool").renderResult)
        let result = AgentToolResult(content: [.text(TextContent(text: String(repeating: "x", count: 1000)))],
            details: AnyCodable(["fullOutputPath": "/tmp/out.txt"]))
        let component = try render(result, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext())
        let lines = plainLines(component, width: 50)
        #expect(lines.first == "")
        #expect(lines.count == 8)
        #expect(Array(lines.dropFirst().prefix(5)) == Array(repeating: String(repeating: "x", count: 50), count: 5))
        #expect(lines[6].hasPrefix("... (15 more lines,"))
        #expect(lines[7] == "Full output: /tmp/out.txt")
        let expanded = try render(result, RenderResultOptions(expanded: true, isPartial: false), theme, ToolRenderContext(lastComponent: component))
        #expect(expanded === component)
        #expect(plainLines(expanded, width: 50).count == 21)
        #expect(!toolTestText(expanded, width: 50).contains("Full output:"))
        let empty = try render(AgentToolResult(content: []), RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext(lastComponent: component))
        #expect(empty === component)
        #expect(empty.render(width: 50).isEmpty)
    }

    @Test func shellUsesSpacerAndLastFiveWrappedLines() throws {
        let render = try #require(createShellRenderers(prompt: "$").renderResult)
        let result = AgentToolResult(content: [.text(TextContent(text: "abcdefghijklmnopqrstuvwx"))])
        let component = try render(result, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext())
        let container = try #require(component as? Container)
        #expect(container.children.first is Spacer)
        #expect(container.children.last is VisualLinePreview)
        let lines = plainLines(component, width: 4)
        #expect(lines.first == "")
        #expect(Array(lines.suffix(5)) == ["efgh", "ijkl", "mnop", "qrst", "uvwx"])
        #expect(lines.count == 7)
    }

    private func plainLines(_ component: Component, width: Int) -> [String] {
        component.render(width: width).map {
            toolTestPlain($0).replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }
    }
}
