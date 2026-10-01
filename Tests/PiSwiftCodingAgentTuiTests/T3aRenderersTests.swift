import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// pi-mono v0.99.1: render-utils.ts, tool-execution-component.test.ts,
// codemode-renderer.test.ts, and extensions/mcp/tools.ts.
@MainActor @Suite(.serialized) struct T3aRenderersTests {
    @Test func genericArgumentsMatchJavascriptJSON() throws {
        let vectors: [(String, String)] = [
            ("1.0", "1"), ("-0", "0"), ("1e-7", "1e-7"), ("1e-6", "0.000001"),
            ("1e20", "100000000000000000000"), ("1e21", "1e+21"),
            ("9007199254740993", "9007199254740992"), ("1.2345678901234567", "1.2345678901234567"),
            ("5e-324", "5e-324"), ("1e23", "1e+23"), ("1000000000000000128", "1000000000000000100"),
            (#""quote\" slash/ backslash\\\t\r\n\u0001""#, #""quote\" slash/ backslash\\\t\r\n\u0001""#),
            (#"{"10":true,"2":null,"z":[1.0,"a/b"]}"#, #"{"2":null,"10":true,"z":[1,"a/b"]}"#),
        ]
        for (input, output) in vectors {
            #expect(toolArgumentJSON(try OrderedJSON.parse(input)) == output)
        }
        let args = try OrderedJSON.parse(#"{"second":2,"first":"one"}"#)
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: args, theme: theme, expanded: false)) == #"tool second=2 first="one""#)
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: ["z": AnyCodable(1), "a": AnyCodable(2)], theme: theme, expanded: false)) == "tool a=2 z=1")
        let row = ToolExecutionComponent(toolName: "tool", args: ["z": AnyCodable(1), "a": AnyCodable(2)], ui: TUI(terminal: ToolTestTerminal()))
        #expect(toolTestText(row).contains("tool a=2 z=1"))
    }

    @Test func genericExpandedValuesAreRawAndIndented() throws {
        let args = try OrderedJSON.parse(#"{"text":"first\r\n\tsecond","nested":{"a":[true,null]}}"#)
        let text = toolTestPlain(formatToolCallWithArgs("tool", args: args, theme: theme, expanded: true))
        #expect(text == "tool\n  text: first\n       second\n  nested: {\n      \"a\": [\n        true,\n        null\n      ]\n    }")
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: nil, theme: theme, expanded: false)) == "tool")
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: [:], theme: theme, expanded: true)) == "tool")
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: .array([.bool(true)]), theme: theme, expanded: false)) == "tool args=[true]")
    }

    @Test func genericCollapsedPreviewHasOneHundredCharacters() {
        let args = ["value": AnyCodable(String(repeating: "a", count: 200))]
        let text = toolTestPlain(formatToolCallWithArgs("tool", args: args, theme: theme, expanded: false))
        #expect(text.dropFirst(5).count == 100)
        #expect(text.hasSuffix("..."))
        let row = ToolExecutionComponent(toolName: "tool", args: args, ui: TUI(terminal: ToolTestTerminal()))
        #expect(toolTestText(row, width: 240).contains(text))
        row.setExpanded(true)
        #expect(toolTestText(row, width: 240).contains("value: " + String(repeating: "a", count: 200)))
    }

    @Test func mcpUsesLabelAndFiveLinePreviewFromMetadata() throws {
        var definition = toolTestDefinition("mcp__server__tool")
        definition.label = "server/tool"
        definition.namespace = ToolNamespace(name: "mcp__server")
        let row = ToolExecutionComponent(toolName: definition.name, args: ["arg": AnyCodable("yes")],
            customTool: definition, sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user"), ui: TUI(terminal: ToolTestTerminal()))
        row.updateResult(toolTestResult((1...8).map { "line\($0)" }.joined(separator: "\n"), tool: definition.name))
        let text = toolTestText(row)
        #expect(text.contains(#"server/tool arg="yes""#))
        #expect(text.contains("line5"))
        #expect(!text.contains("line6"))
        #expect(text.contains("3 more lines"))
        row.setExpanded(true)
        #expect(toolTestText(row).contains("line8"))
        let renderer = createMcpRenderers(label: "server/tool")
        let renderError = try #require(renderer.renderResult)
        let error = try renderError(AgentToolResult(content: [.text(TextContent(text: "bad"))]), RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext(isError: true))
        #expect(error.render(width: 80).joined().contains(theme.fg(.error, "bad")))
    }

    @Test func codemodeRemovesHeaderAndShowsCallCosts() throws {
        let result = AgentToolResult(content: [.text(TextContent(text: "Script completed\nWall time 0.1 seconds\nOutput:\n")), .text(TextContent(text: "hello"))], details: AnyCodable(["calls": [["name": "read", "args": #"{"path":"a"}"#, "status": "ok", "durationMs": 5]]]))
        let render = try #require(createCodemodeRenderers().renderResult)
        let component = try render(result, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext())
        #expect(toolTestText(component).trimmingCharacters(in: .newlines) == "✓ read {\"path\":\"a\"} 5ms\n\nhello")
        let costs = AgentToolResult(content: [], details: AnyCodable(["calls": [
            ["name": "classify", "args": "", "status": "ok", "cost": 0.000012936],
            ["name": "model", "args": "", "status": "ok", "cost": 0.02],
            ["name": "read", "args": "", "status": "ok"],
        ]]))
        let text = toolTestText(try render(costs, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext()))
        #expect(text.trimmingCharacters(in: .newlines) == "✓ classify $0.000013\n✓ model $0.02\n✓ read\nModel calls: $0.02")
        #expect(codemodeCost(0.009999) == "$0.010")
        #expect(codemodeCost(9.999e-7) == "$0.0000010")
    }

    @Test func codemodePreviewsScriptCallsAndOutput() throws {
        let renderers = createCodemodeRenderers()
        let call = try #require(renderers.renderCall)
        let script = (1...12).map { "const value\($0) = \($0);" }.joined(separator: "\n")
        let component = try call(["code": AnyCodable(script)], theme, ToolRenderContext())
        #expect(toolTestText(component).contains("value10"))
        #expect(!toolTestText(component).contains("value11"))
        #expect(toolTestText(component).contains("2 more lines"))
        #expect(component.render(width: 120).joined().contains(theme.fg(.syntaxKeyword, "const")))
        let calls = (1...10).map { ["name": "call\($0)", "args": String(repeating: "x", count: 100), "status": $0 == 10 ? "error" : "running", "error": "one\ntwo"] }
        let result = AgentToolResult(content: [.text(TextContent(text: (1...7).map { "out\($0)" }.joined(separator: "\n")))], details: AnyCodable(["calls": calls, "fullOutputPath": "/tmp/full.txt"]))
        let render = try #require(renderers.renderResult)
        let text = toolTestText(try render(result, RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext()))
        #expect(!text.contains("call1 "))
        #expect(text.contains("2 earlier calls"))
        #expect(text.contains("… call3"))
        #expect(text.contains("✗ call10"))
        #expect(text.contains("out5"))
        #expect(!text.contains("out6"))
        #expect(text.contains("Full output: /tmp/full.txt"))
        let expanded = toolTestText(try render(result, RenderResultOptions(expanded: true, isPartial: false), theme, ToolRenderContext()))
        #expect(expanded.contains("call1 "))
        #expect(expanded.contains("    one\n    two"))
        #expect(expanded.contains("out7"))
        let partial = toolTestText(try render(result, RenderResultOptions(expanded: false, isPartial: true), theme, ToolRenderContext()))
        #expect(!partial.contains("out1"))
    }

    @Test func codemodeErrorWithoutHeaderIsVisibleAndSourceIsRequired() throws {
        let renderer = try #require(createCodemodeRenderers().renderResult)
        let value = try renderer(AgentToolResult(content: [.text(TextContent(text: "invalid options"))]), RenderResultOptions(expanded: false, isPartial: false), theme, ToolRenderContext(isError: true))
        #expect(toolTestText(value).contains("invalid options"))
        #expect(value.render(width: 100).joined().contains(theme.fg(.error, "invalid options")))
        #expect(withBuiltInRenderers("codemode", nil) == nil)
        #expect(withBuiltInRenderers("codemode", nil, sourceInfo: SourceInfo(path: "builtin:codemode", source: "builtin", scope: "user")) != nil)
    }

    @Test func readNullOffsetAndLimitAreAbsent() {
        for args in [
            ["path": AnyCodable("src/example.ts"), "offset": AnyCodable(NSNull()), "limit": AnyCodable(NSNull())],
            ["path": AnyCodable("src/example.ts"), "offset": AnyCodable(NSNull())],
            ["path": AnyCodable("src/example.ts"), "limit": AnyCodable(NSNull())],
        ] {
            let row = ToolExecutionComponent(toolName: "read", args: args, ui: TUI(terminal: ToolTestTerminal()))
            #expect(toolTestText(row).contains("read src/example.ts"))
            #expect(!toolTestText(row).contains("src/example.ts:"))
        }
    }

    @Test func returnedBashErrorUsesErrorBackgroundAndKeepsOutput() {
        let row = ToolExecutionComponent(toolName: "bash", args: ["command": AnyCodable("false")], ui: TUI(terminal: ToolTestTerminal()))
        row.markExecutionStarted()
        // C40: this is a returned result with isError, not an execution exception.
        row.updateResult(toolTestResult("Command failed", tool: "bash", isError: true))
        let lines = row.render(width: 100)
        #expect(toolTestText(row).contains("Command failed"))
        #expect(toolTestText(row).contains("Took"))
        #expect(!toolTestText(row).contains("Elapsed"))
        #expect(lines.contains { $0.contains(theme.bg(.toolErrorBg, "").components(separatedBy: "\u{001B}").dropFirst().first.map { "\u{001B}" + $0 } ?? "missing") })
    }
}
