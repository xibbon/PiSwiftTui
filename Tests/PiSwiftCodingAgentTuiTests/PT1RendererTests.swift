import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// Tagged v1.5.2 renderer follow-ups from CTA and CCM.
@MainActor @Suite(.serialized) struct PT1RendererTests {
    @Test func homeDisplayRequiresAPathBoundary() {
        let home = getHomeDir()
        #expect(shortenPath(home) == "~")
        #expect(shortenPath(home + "/file.swift") == "~/file.swift")
        #expect(shortenPath(home + "-other/file.swift") == home + "-other/file.swift")
        #expect(shortenPath("relative/file.swift") == "relative/file.swift")
    }

    @Test func codemodeRetainsItsHighlighterAcrossRedraws() throws {
        var count = 0
        let highlighter = ToolCodeHighlighter { source, _ in count += 1; return [source] }
        let state = ToolRenderState()
        state.values["codemodeScriptHighlighter"] = highlighter
        let call = try #require(createCodemodeRenderers().renderCall)
        let args = ["code": AnyCodable("return 42\r\n")]
        let first = try call(args, theme, ToolRenderContext(state: state))
        _ = try call(args, theme, ToolRenderContext(lastComponent: first, state: state, argsComplete: true, expanded: true))
        #expect(count == 1)
        #expect(state.values["codemodeScriptHighlighter"] as? ToolCodeHighlighter === highlighter)
        _ = try call(["code": AnyCodable("return 43")], theme, ToolRenderContext(state: state))
        #expect(count == 2)
    }

    @Test func completeWriteDropsStreamingCacheAndReusesHighlighter() throws {
        let call = try #require(createWriteRenderers().renderCall)
        let args = ["path": AnyCodable("test.swift"), "content": AnyCodable("let value = 1\n")]
        let first = try #require(try call(args, theme, ToolRenderContext()) as? WriteCallRenderComponent)
        #expect(first.cache != nil)
        let highlighter = first.highlighter
        let complete = try #require(try call(args, theme, ToolRenderContext(lastComponent: first, argsComplete: true)) as? WriteCallRenderComponent)
        #expect(complete === first)
        #expect(complete.cache == nil)
        #expect(complete.highlighter === highlighter)
        let expanded = try call(args, theme, ToolRenderContext(lastComponent: complete, argsComplete: true, expanded: true))
        #expect(toolTestText(expanded).contains("let value = 1"))
    }

    private func result(_ name: String, text: String, details: [String: Any], expanded: Bool = true) throws -> String {
        let render = try #require(createAllToolRenderers()[name]?.renderResult)
        return toolTestText(try render(AgentToolResult(content: [.text(TextContent(text: text))], details: AnyCodable(details)),
            RenderResultOptions(expanded: expanded, isPartial: false), theme, ToolRenderContext(outputPad: 0)), width: 500)
    }

    @Test func grepAndReadKeepExactTruncationNotices() throws {
        #expect(try result("grep", text: "file:1: needle", details: ["matchLimitReached": 2, "linesTruncated": true,
            "truncation": ["truncated": true, "maxBytes": 1024]]) == "\nfile:1: needle\n[Truncated: 2 matches limit, 1.0KB limit, some lines truncated]")
        #expect(try result("read", text: "line", details: ["truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 1, "totalLines": 20, "maxLines": 1]]) == "\nline\n[Truncated: showing 1 of 20 lines (1 line limit)]")
    }

    @Test func shellKeepsTimeoutTextAndReplacesOnlyTruncatedFooters() throws {
        let timeout = "Command timed out after 1 seconds. The shell exited with code 0 after 0.1 seconds, but background processes it started kept writing output until the timeout."
        #expect(try result("bash", text: timeout, details: [:]).contains(timeout))
        let body = "output\n\n[Full output: /tmp/full.log]"
        let untruncated = try result("bash", text: body, details: ["fullOutputPath": "/tmp/full.log"])
        #expect(untruncated.components(separatedBy: "Full output:").count == 3)
        let truncated = try result("bash", text: body, details: ["fullOutputPath": "/tmp/full.log", "truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 1, "totalLines": 5]])
        #expect(truncated == "\noutput\n\n[Full output: /tmp/full.log. Truncated: showing 1 of 5 lines]")
    }

    @Test func editDisplaysWindowedDiffWithoutChangingItsRows() throws {
        let diff = " 100 before\n-101 old\n+101 new\n 102 after\n    ...\n 900 before\n-901 old\n+901 new"
        #expect(try result("edit", text: "", details: ["diff": diff]) == "\n" + diff)
    }
}
