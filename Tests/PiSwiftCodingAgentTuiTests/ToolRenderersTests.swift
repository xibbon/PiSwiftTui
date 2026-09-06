import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct ToolRenderersTests {
    private func context(args: [String: AnyCodable] = [:], state: ToolRenderState = ToolRenderState(), cwd: String = "/tmp/pi-render-tests", expanded: Bool = false, error: Bool = false, complete: Bool = false, partial: Bool = false, started: Bool = false, last: Component? = nil, invalidate: @escaping () -> Void = {}) -> ToolRenderContext {
        ToolRenderContext(args: args, toolCallId: "renderer-test", invalidate: invalidate, lastComponent: last, state: state, cwd: cwd, executionStarted: started, argsComplete: complete, isPartial: partial, expanded: expanded, showImages: false, isError: error)
    }

    private func call(_ name: String, _ args: [String: AnyCodable], context supplied: ToolRenderContext? = nil) throws -> Component {
        let renderer = try #require(createAllToolRenderers()[name]?.renderCall)
        return try renderer(args, theme, supplied ?? context(args: args))
    }

    private func result(_ name: String, _ output: String, details: [String: Any]? = nil, context supplied: ToolRenderContext? = nil) throws -> Component {
        let context = supplied ?? context()
        let renderer = try #require(createAllToolRenderers()[name]?.renderResult)
        return try renderer(AgentToolResult(content: [.text(TextContent(text: output))], details: details.map(AnyCodable.init)), RenderResultOptions(expanded: context.expanded, isPartial: context.isPartial), theme, context)
    }

    @Test func registryContainsSevenToolsAndMergesEachSlot() throws {
        #expect(Set(createAllToolRenderers().keys) == Set(["read", "bash", "edit", "write", "grep", "find", "ls"]))
        #expect(createAllToolRenderers()["edit"]?.renderShell == .self)
        #expect(withBuiltInRenderers("unknown", nil) == nil)
        var definition = toolTestDefinition("edit")
        definition.renderShell = .default
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("custom", paddingX: 0, paddingY: 0) } }
        let merged = try #require(withBuiltInRenderers("edit", definition))
        #expect(merged.renderShell == .default)
        #expect(merged.renderResult != nil)
        let customCall = try #require(merged.renderCall)
        #expect(toolTestText(try customCall([:], theme, context())).contains("custom"))
        #expect(withBuiltInRenderers("custom", toolTestDefinition())?.renderShell == .default)
    }

    @Test func invalidArgumentsStayVisible() throws {
        for name in ["read", "edit", "write", "ls"] {
            #expect(toolTestText(try call(name, ["path": AnyCodable(42)])).contains("[invalid arg]"))
        }
        for name in ["grep", "find"] {
            #expect(toolTestText(try call(name, ["pattern": AnyCodable(42)])).contains("[invalid arg]"))
            #expect(toolTestText(try call(name, ["path": AnyCodable(42)])).contains("[invalid arg]"))
        }
        #expect(toolTestText(try call("bash", ["command": AnyCodable(42)])).contains("[invalid arg]"))
        #expect(toolTestText(try call("write", ["content": AnyCodable(42)])).contains("[invalid content arg - expected string]"))
    }

    @Test func missingAndNullArgumentsUsePlaceholders() throws {
        #expect(toolTestText(try call("read", [:])).contains("read ..."))
        #expect(toolTestText(try call("read", ["path": AnyCodable(NSNull())])).contains("read ..."))
        #expect(toolTestText(try call("ls", [:])).contains("ls ."))
        #expect(toolTestText(try call("grep", [:])).contains("grep // in ."))
    }

    @Test func readClassifiesDocsExamplesAndResourceNames() throws {
        let root = URL(fileURLWithPath: getReadmePath()).deletingLastPathComponent().path
        for (path, expected) in [(root + "/docs/guide.md", "read docs docs/guide.md"), (root + "/examples/demo.ts", "read docs examples/demo.ts"), ("/tmp/pi-render-tests/CLAUDE.md", "read resource CLAUDE.md"), ("/tmp/pi-render-tests/AGENTS.MD", "read resource AGENTS.MD"), ("/tmp/pi-render-tests/AGENTS.override.md", "read resource AGENTS.override.md")] {
            #expect(toolTestText(try call("read", ["path": AnyCodable(path)])).contains(expected))
        }
        #expect(!toolTestText(try call("read", ["path": AnyCodable(root + "-other/docs/guide.md")])).contains("read docs"))
    }

    @Test func readLineRangesUseOffsetAndLimit() throws {
        #expect(toolTestText(try call("read", ["path": AnyCodable("file.txt"), "limit": AnyCodable(5)])).contains("file.txt:1-5"))
        #expect(toolTestText(try call("read", ["path": AnyCodable("file.txt"), "offset": AnyCodable(5)])).contains("file.txt:5"))
    }

    @Test func readResultHidesUntilExpandedButErrorsRemainVisible() throws {
        #expect(toolTestText(try result("read", "hidden")).isEmpty)
        #expect(toolTestText(try result("read", "visible", context: context(expanded: true))).contains("visible"))
        let error = "let failed = true"
        let rendered = try result("read", error, context: context(args: ["path": AnyCodable("file.swift")], error: true))
        #expect(rendered.render(width: 120).joined().contains(theme.fg(.toolOutput, error)))
    }

    @Test func readTrimsTrailingEmptyLines() throws {
        let rendered = toolTestText(try result("read", "one\ntwo\n\n", context: context(expanded: true)))
        #expect(rendered == "\none\ntwo")
    }

    @Test func readTruncationFootersUseToolDetails() throws {
        let cases: [([String: Any], String)] = [
            (["truncated": true, "firstLineExceedsLimit": true, "maxBytes": 1024], "[First line exceeds 1.0KB limit]"),
            (["truncated": true, "truncatedBy": "lines", "outputLines": 10, "totalLines": 50, "maxLines": 10], "[Truncated: showing 10 of 50 lines (10 line limit)]"),
            (["truncated": true, "truncatedBy": "bytes", "outputLines": 10, "totalLines": 50, "maxBytes": 1024], "[Truncated: 10 lines shown (1.0KB limit)]")
        ]
        for (details, expected) in cases {
            #expect(toolTestText(try result("read", "text", details: ["truncation": details], context: context(expanded: true))).contains(expected))
        }
        let errorOutput = (1...15).map { "error-\($0)" }.joined(separator: "\n")
        let collapsed = toolTestText(try result("read", errorOutput, context: context(error: true)))
        #expect(collapsed.contains("error-10"))
        #expect(!collapsed.contains("error-11"))
        #expect(collapsed.contains("5 more lines"))
    }

    @Test func writePreviewHasTenLinesAndTotalHint() throws {
        let args = ["path": AnyCodable("test.txt"), "content": AnyCodable((1...15).map { "line-\($0)" }.joined(separator: "\n") + "\n\n")]
        let collapsed = toolTestText(try call("write", args))
        #expect(collapsed.contains("line-10"))
        #expect(!collapsed.contains("line-11"))
        #expect(collapsed.contains("5 more lines, 15 total"))
        let expanded = toolTestText(try call("write", args, context: context(args: args, expanded: true)))
        #expect(expanded.hasSuffix("line-15"))
    }

    @Test func writeStreamingHighlightMatchesFullRebuild() throws {
        let state = ToolRenderState()
        var previous: Component?
        let source = (1...80).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        for count in [17, 100, 500, source.count] {
            let partial = String(source.prefix(count))
            let args = ["path": AnyCodable("test.swift"), "content": AnyCodable(partial)]
            previous = try call("write", args, context: context(args: args, state: state, expanded: true, partial: true, last: previous))
        }
        let args = ["path": AnyCodable("test.swift"), "content": AnyCodable(source)]
        let full = try call("write", args, context: context(args: args, expanded: true, complete: true))
        let streamed = try #require(previous)
        #expect(streamed.render(width: 120) == full.render(width: 120))
        let final = try call("write", args, context: context(args: args, state: state, expanded: true, complete: true, last: previous))
        #expect(final.render(width: 120) == full.render(width: 120))
        // A changed prefix must discard the append cache.
        let replacement = ["path": AnyCodable("test.swift"), "content": AnyCodable("struct Replacement {}\n")]
        let changed = try call("write", replacement, context: context(args: replacement, state: state, expanded: true, last: final))
        #expect(toolTestText(changed).contains("struct Replacement {}"))
        #expect(!toolTestText(changed).contains("value80"))
    }


    @Test func writeStreamingPreservesUnicodeScalarsAndCRLF() throws {
        let state = ToolRenderState()
        var previous: Component?
        for source in ["let name = \"e", "let name = \"e\u{0301}\"\r", "let name = \"e\u{0301}\"\r\nlet flag = \"🇺", "let name = \"e\u{0301}\"\r\nlet flag = \"🇺🇸\"\n"] {
            let args = ["path": AnyCodable("test.swift"), "content": AnyCodable(source)]
            let streamed = try call("write", args, context: context(args: args, state: state, expanded: true, last: previous))
            let rebuilt = try call("write", args, context: context(args: args, expanded: true, complete: true))
            #expect(streamed.render(width: 120) == rebuilt.render(width: 120))
            previous = streamed
        }
    }

    @Test func expandHintsUseConfiguredApplicationKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tool-keys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            _ = KeybindingsManager.create()
        }
        try "{\"expandTools\": \"ctrl+e\"}".write(to: directory.appendingPathComponent("keybindings.json"), atomically: true, encoding: .utf8)
        _ = KeybindingsManager.create(agentDir: directory.path)
        let output = toolTestText(try call("read", ["path": AnyCodable("/tmp/demo/SKILL.md")]))
        #expect(output.contains("ctrl+e to expand"))
        let preview = toolTestText(try result("grep", (1...20).map { "line-\($0)" }.joined(separator: "\n")))
        #expect(preview.contains("ctrl+e to expand"))
    }

    @Test func writeResultsShowOnlyErrors() throws {
        #expect(toolTestText(try result("write", "wrote file")).isEmpty)
        let error = try result("write", "cannot write", context: context(error: true))
        #expect(toolTestText(error).contains("cannot write"))
    }

    @Test func shellCallIncludesTimeoutAndReplacesTabs() throws {
        let output = toolTestText(try call("bash", ["command": AnyCodable("echo\tok"), "timeout": AnyCodable(12)]))
        #expect(output.contains("$ echo   ok"))
        #expect(output.contains("(timeout 12s)"))
    }

    @Test func shellPreviewKeepsLastFiveVisualLinesAndReflows() throws {
        let output = (1...12).map { "line-\($0)" }.joined(separator: "\n")
        let preview = try result("bash", output)
        let wide = toolTestText(preview, width: 120)
        #expect(wide.contains("7 earlier lines"))
        #expect(wide.contains("line-8"))
        #expect(wide.contains("line-12"))
        #expect(!wide.contains("line-7"))
        #expect(wide.range(of: "earlier lines")!.lowerBound < wide.range(of: "line-8")!.lowerBound)
        let narrow = toolTestText(preview, width: 5)
        #expect(narrow != wide)
        #expect(preview.render(width: 5).allSatisfy { visibleWidth($0) <= 5 })
    }

    @Test func shellStripsFooterOnlyForFinalKnownFullOutput() throws {
        let output = "last line\n\n[Showing lines 5-10 of 10. Full output: /tmp/output.log]"
        let details: [String: Any] = ["fullOutputPath": "/tmp/output.log", "truncation": ["truncated": true, "truncatedBy": "lines", "outputLines": 6, "totalLines": 10]]
        let final = toolTestText(try result("bash", output, details: details, context: context(expanded: true)))
        #expect(final.components(separatedBy: "Full output:").count == 2)
        #expect(!final.contains("[Showing lines"))
        let partial = toolTestText(try result("bash", output, details: details, context: context(expanded: true, partial: true)))
        #expect(partial.contains("[Showing lines"))
        let noTruncation = toolTestText(try result("bash", output, details: ["fullOutputPath": "/tmp/output.log"], context: context(expanded: true)))
        #expect(!noTruncation.contains("[Showing lines"))
        let arbitrary = toolTestText(try result("bash", "body\n\n[mention /tmp/output.log]", details: ["fullOutputPath": "/tmp/output.log"], context: context(expanded: true)))
        #expect(arbitrary.contains("[mention /tmp/output.log]"))
        let unknown = toolTestText(try result("bash", output, context: context(expanded: true)))
        #expect(unknown.contains("[Showing lines"))
    }

    @Test func shellTimerInvalidatesThenStopsOnFinalResult() async throws {
        let state = ToolRenderState()
        var invalidations = 0
        let args = ["command": AnyCodable("sleep 10")]
        _ = try call("bash", args, context: context(args: args, state: state, partial: true, started: true, invalidate: { invalidations += 1 }))
        let partial = try result("bash", "", context: context(args: args, state: state, partial: true, started: true, invalidate: { invalidations += 1 }))
        #expect(toolTestText(partial).contains("Elapsed"))
        try await Task.sleep(for: .milliseconds(1150))
        #expect(invalidations >= 1)
        let final = try result("bash", "", context: context(args: args, state: state, started: true, invalidate: { invalidations += 1 }))
        #expect(toolTestText(final).contains("Took"))
        #expect(!toolTestText(final).contains("Elapsed"))
        let errorState = ToolRenderState()
        var errorInvalidations = 0
        _ = try call("bash", args, context: context(args: args, state: errorState, partial: true, started: true))
        _ = try result("bash", "", context: context(args: args, state: errorState, partial: true, started: true, invalidate: { errorInvalidations += 1 }))
        let errorResult = try result("bash", "failed", context: context(args: args, state: errorState, error: true, partial: true, started: true, invalidate: { errorInvalidations += 1 }))
        #expect(toolTestText(errorResult).contains("Took"))
        #expect(!toolTestText(errorResult).contains("Elapsed"))
        let settledCount = invalidations
        try await Task.sleep(for: .milliseconds(1100))
        #expect(invalidations == settledCount)
        #expect(errorInvalidations == 0)
    }

    @Test func editPreviewUsesFileAndSupportsBothArgumentForms() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-edit-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "before\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        for input in [["oldText": AnyCodable("before"), "newText": AnyCodable("after")], ["edits": AnyCodable([["oldText": "before", "newText": "after"]])]] {
            let args = input.merging(["path": AnyCodable("file.txt")]) { _, new in new }
            let state = ToolRenderState()
            var invalidations = 0
            let header = try call("edit", args, context: context(args: args, state: state, cwd: directory.path, complete: true, invalidate: { invalidations += 1 }))
            for _ in 0..<10 { await Task.yield() }
            let rendered = try call("edit", args, context: context(args: args, state: state, cwd: directory.path, complete: true, last: header))
            #expect(toolTestText(rendered).contains("before"))
            #expect(toolTestText(rendered).contains("after"))
            #expect(invalidations == 1)
            #expect(try String(contentsOf: directory.appendingPathComponent("file.txt"), encoding: .utf8) == "before\n")
        }
    }

    @Test func editSuppressesMatchingPreviewError() async throws {
        let args = ["path": AnyCodable("/tmp/pi-missing-" + UUID().uuidString), "oldText": AnyCodable("before"), "newText": AnyCodable("after")]
        let state = ToolRenderState()
        let header = try call("edit", args, context: context(args: args, state: state, complete: true))
        for _ in 0..<10 { await Task.yield() }
        let outcome = computeEditsDiff(path: args["path"]!.value as! String, edits: [EditReplacement(oldText: "before", newText: "after")], cwd: "/tmp/pi-render-tests")
        guard case .error(let failure) = outcome else { Issue.record("Expected missing-file preview error"); return }
        let error = failure.error
        let updated = try call("edit", args, context: context(args: args, state: state, complete: true, last: header))
        #expect(toolTestText(updated).contains(error))
        let rendered = try result("edit", error, context: context(args: args, state: state, error: true))
        #expect(toolTestText(rendered).isEmpty)
        #expect(toolTestText(try result("edit", "another failure", context: context(args: args, state: state, error: true))).contains("another failure"))
    }

    @Test func editResultDiffReplacesPreview() throws {
        let args = ["path": AnyCodable("file.swift")]
        let state = ToolRenderState()
        let header = try call("edit", args, context: context(args: args, state: state))
        _ = try result("edit", "", details: ["diff": "+1 let oldValue = 1", "firstChangedLine": 1], context: context(args: args, state: state))
        #expect(toolTestText(header).contains("oldValue"))
        let rendered = try result("edit", "", details: ["diff": "+1 let newValue = 2", "firstChangedLine": 1], context: context(args: args, state: state))
        #expect(toolTestText(header).contains("newValue"))
        #expect(!toolTestText(header).contains("oldValue"))
        #expect(toolTestText(rendered).contains("newValue"))
    }

    @Test func grepFindAndLsCallsMatchUpstream() throws {
        #expect(toolTestText(try call("grep", ["pattern": AnyCodable("needle"), "path": AnyCodable("src"), "glob": AnyCodable("*.swift"), "limit": AnyCodable(5)])) == "grep /needle/ in src (*.swift) limit 5")
        #expect(toolTestText(try call("find", ["pattern": AnyCodable("*.swift"), "path": AnyCodable("src"), "limit": AnyCodable(5)])) == "find *.swift in src (limit 5)")
        #expect(toolTestText(try call("ls", ["limit": AnyCodable(5)])) == "ls . (limit 5)")
    }

    @Test func grepFindAndLsLineCapsAndTruncationWarnings() throws {
        for (name, cap, key, noun) in [("grep", 15, "matchLimitReached", "matches"), ("find", 20, "resultLimitReached", "results"), ("ls", 20, "entryLimitReached", "entries")] {
            let output = (1...25).map { "entry-\($0)" }.joined(separator: "\n")
            var details: [String: Any] = [key: 25, "truncation": ["truncated": true, "maxBytes": 1024]]
            if name == "grep" { details["linesTruncated"] = true }
            let collapsed = toolTestText(try result(name, output, details: details))
            #expect(collapsed.contains("entry-\(cap)"))
            #expect(!collapsed.contains("entry-\(cap + 1)"))
            #expect(collapsed.contains("\(25 - cap) more lines"))
            #expect(collapsed.contains("[Truncated: 25 \(noun) limit, 1.0KB limit" + (name == "grep" ? ", some lines truncated]" : "]")))
            #expect(toolTestText(try result(name, output, context: context(expanded: true))).contains("entry-25"))
        }
    }

    @Test func fileLinksRequireTerminalCapability() throws {
        let saved = getCapabilities()
        defer { setCapabilities(saved) }
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        let args = ["path": AnyCodable("a file.txt")]
        let disabled = try call("read", args).render(width: 120).joined()
        #expect(!disabled.contains("\u{001B}]8;;"))
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true))
        let enabled = try call("read", args).render(width: 120).joined()
        #expect(enabled.contains("\u{001B}]8;;file:///tmp/pi-render-tests/a%20file.txt"))
        #expect(try call("ls", [:]).render(width: 120).joined().contains("\u{001B}]8;;file:///tmp/pi-render-tests"))
    }

    @Test func resultTextRemovesAnsiCarriageReturnAndBinaryControls() throws {
        let output = "\u{001B}[31mred\u{001B}[0m\r\nnext\u{0000}line"
        let clean = getTextOutput(AgentToolResult(content: [.text(TextContent(text: output))], details: nil), showImages: false)
        #expect(clean == "red\nnextline")
        let rendered = try result("read", output, context: context(expanded: true))
        let plain = toolTestText(rendered)
        #expect(plain.contains("red\nnext"))
        #expect(!plain.contains("\r"))
        #expect(!plain.contains("\u{0000}"))
        #expect(!rendered.render(width: 120).joined().contains("\u{001B}[31m"))
    }
}
