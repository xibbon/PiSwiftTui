import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private final class F4THtmlLines: Component {
    var lines: [String]
    var widths: [Int] = []
    init(_ lines: [String]) { self.lines = lines }
    func render(width: Int) -> [String] {
        widths.append(width)
        return lines
    }
}

private enum F4TRenderError: Error { case failed }

@MainActor @Suite(.serialized)
struct F4TToolHtmlRendererTests {
    @Test func trimsResultSpacingLikeUpstreamAndKeepsInternalBlankLines() async throws {
        let component = F4THtmlLines(["", "\u{1b}[31mone\u{1b}[0m", "two", ""])
        let slots = ToolRenderers(renderResult: { _, _, _, _ in component })
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
        let html = try #require(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false))
        #expect(html.expanded == "<div class=\"ansi-line\"><span style=\"color:#800000\">one</span></div><div class=\"ansi-line\">two</div>")
        #expect(html.collapsed == nil)
        component.lines = ["\u{1b}[31m \t\u{1b}[0m", "one", "", "two", " \t"]
        let internalBlank = try #require(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false))
        #expect(internalBlank.expanded == ansiLinesToHtml(["one", "", "two"]))
    }

    @Test func rendersAtDefaultAndSuppliedWidthWithoutTrimmingCallLines() async throws {
        for width in [100, 73] {
            let component = F4THtmlLines(["", "call", ""])
            let slots = ToolRenderers(renderCall: { _, _, _ in component }, renderResult: { _, _, _, _ in component })
            let renderer: TuiToolHtmlRenderer
            if width == 100 {
                renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
            } else {
                renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", width: width, getRenderers: { _ in slots })
            }
            let call = await renderer.renderCall(toolCallId: "id", name: "custom", arguments: try OrderedJSON.parse("{}"))
            #expect(call == ansiLinesToHtml(["", "call", ""]))
            _ = await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false)
            #expect(component.widths == [width, width, width])
        }
    }

    @Test func sharesStateAndReusesComponentsWithCorrectContexts() async throws {
        let activeTheme = theme
        let callComponent = F4THtmlLines(["call"])
        let collapsedComponent = F4THtmlLines(["short"])
        let expandedComponent = F4THtmlLines(["long"])
        var calls: [ToolRenderContext] = []
        var results: [ToolRenderContext] = []
        var modes: [Bool] = []
        var names: [String] = []
        let slots = ToolRenderers(renderCall: { args, suppliedTheme, context in
            #expect(suppliedTheme.name == activeTheme.name)
            #expect(suppliedTheme.fg(.accent, "sample") == activeTheme.fg(.accent, "sample"))
            #expect(args["value"]?.value as? Int == 7)
            context.state.values["token"] = "shared"
            context.invalidate()
            calls.append(context)
            return callComponent
        }, renderResult: { result, options, suppliedTheme, context in
            #expect(suppliedTheme.name == activeTheme.name)
            #expect(context.state.values["token"] as? String == "shared")
            #expect(context.args["value"]?.value as? Int == 7)
            #expect(result.isError == true)
            #expect(result.details?.value as? String == "details")
            #expect(result.content.count == 1)
            if case .text(let content) = result.content[0] { #expect(content.text == "output") }
            else { Issue.record("Expected text content") }
            #expect(options.expanded == context.expanded)
            #expect(options.isPartial == false)
            context.invalidate()
            modes.append(options.expanded)
            results.append(context)
            return options.expanded ? expandedComponent : collapsedComponent
        })
        let renderer = TuiToolHtmlRenderer(theme: activeTheme, cwd: "/tmp/f4t-cwd", getRenderers: { name in
            names.append(name)
            return slots
        })
        let arguments = try OrderedJSON.parse(#"{"value":7}"#)
        _ = await renderer.renderCall(toolCallId: "id", name: "custom", arguments: arguments)
        _ = await renderer.renderCall(toolCallId: "id", name: "custom", arguments: arguments)
        for _ in 0..<2 {
            let html = try #require(await renderer.renderResult(toolCallId: "id", name: "custom", result: [.text(TextContent(text: "output"))], details: AnyCodable("details"), isError: true))
            #expect(html.collapsed == ansiLinesToHtml(["short"]))
            #expect(html.expanded == ansiLinesToHtml(["long"]))
        }
        #expect(names == Array(repeating: "custom", count: 4))
        #expect(calls.count == 2)
        #expect(calls[0].lastComponent == nil)
        #expect(calls[1].lastComponent === callComponent)
        #expect(results[0].lastComponent == nil)
        #expect(results[1].lastComponent === collapsedComponent)
        #expect(results[2].lastComponent === expandedComponent)
        #expect(results[3].lastComponent === collapsedComponent)
        #expect(modes == [false, true, false, true])
        for context in calls + results {
            #expect(context.state === calls[0].state)
            #expect(context.cwd == "/tmp/f4t-cwd")
            #expect(context.toolCallId == "id")
            #expect(context.executionStarted)
            #expect(context.argsComplete)
            #expect(!context.showImages)
        }
        for context in calls {
            #expect(!context.expanded)
            #expect(context.isPartial)
            #expect(!context.isError)
        }
        for context in results {
            #expect(!context.isPartial)
            #expect(context.isError)
        }
    }

    @Test func separatesStateComponentsAndArgumentsByCallId() async throws {
        var contexts: [ToolRenderContext] = []
        let slots = ToolRenderers(renderCall: { args, _, context in
            contexts.append(context)
            context.state.values["value"] = args["value"]?.value
            return F4THtmlLines([context.toolCallId])
        }, renderResult: { _, _, _, context in
            #expect(context.state.values["value"] as? Int == context.args["value"]?.value as? Int)
            return F4THtmlLines([String(context.args["value"]?.value as? Int ?? -1)])
        })
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
        _ = await renderer.renderCall(toolCallId: "one", name: "custom", arguments: try OrderedJSON.parse(#"{"value":1}"#))
        _ = await renderer.renderCall(toolCallId: "two", name: "custom", arguments: try OrderedJSON.parse(#"{"value":2}"#))
        #expect(contexts[0].state !== contexts[1].state)
        #expect(contexts.allSatisfy { $0.lastComponent == nil })
        for (id, value) in [("two", "2"), ("one", "1")] {
            let html = try #require(await renderer.renderResult(toolCallId: id, name: "custom", result: [], details: nil, isError: false))
            #expect(html.expanded == ansiLinesToHtml([value]))
        }
    }

    @Test func omitsCollapsedWhenEqualOrEmptyAndKeepsEmptyExpanded() async throws {
        for (short, long) in [(["same"], ["same"]), (["", " \t"], ["long"]), (["short"], ["", "\u{1b}[0m"])] {
            let slots = ToolRenderers(renderResult: { _, options, _, _ in F4THtmlLines(options.expanded ? long : short) })
            let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
            let html = try #require(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false))
            if long == ["", "\u{1b}[0m"] {
                #expect(html.expanded == "")
                #expect(html.collapsed == ansiLinesToHtml(["short"]))
            } else {
                #expect(html.collapsed == nil)
                #expect(html.expanded == ansiLinesToHtml(long))
            }
        }
    }

    @Test func returnsNilForMissingSlotsAndRendererErrors() async throws {
        let arguments = try OrderedJSON.parse("{}")
        let slots: [ToolRenderers?] = [nil, ToolRenderers(), ToolRenderers(renderCall: { _, _, _ in throw F4TRenderError.failed }, renderResult: { _, _, _, _ in throw F4TRenderError.failed })]
        for slot in slots {
            let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slot })
            #expect(await renderer.renderCall(toolCallId: "id", name: "custom", arguments: arguments) == nil)
            #expect(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false) == nil)
        }
        let expandedError = ToolRenderers(renderResult: { _, options, _, _ in
            if options.expanded { throw F4TRenderError.failed }
            return F4THtmlLines(["short"])
        })
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in expandedError })
        #expect(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false) == nil)
    }

    @Test func keepsF3ArgumentOrderForCallsAndStoredResultArguments() async throws {
        let arguments = try OrderedJSON.parse(#"{"z":{"z":1,"a":2,"10":10,"2":2},"a":0,"10":10,"2":2}"#)
        var seen: [[String: AnyCodable]] = []
        let slots = ToolRenderers(renderCall: { args, _, _ in
            seen.append(args)
            return F4THtmlLines(["call"])
        }, renderResult: { _, _, _, context in
            seen.append(context.args)
            return F4THtmlLines(["result"])
        })
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
        _ = await renderer.renderCall(toolCallId: "id", name: "custom", arguments: arguments)
        _ = await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false)
        #expect(seen.count == 3)
        for args in seen {
            #expect(orderedToolArguments(args).map(\.key) == ["2", "10", "z", "a"])
            #expect(toolArgumentsToOrderedJSON(args)["z"]?.objectEntries?.map(\.0) == ["2", "10", "z", "a"])
        }
    }

    @Test func storesArgumentsWithoutCallSlotForResultRenderer() async throws {
        let slots = ToolRenderers(renderResult: { _, _, _, context in
            #expect(context.args["value"]?.value as? Int == 3)
            return F4THtmlLines(["result"])
        })
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
        #expect(await renderer.renderCall(toolCallId: "id", name: "custom", arguments: try OrderedJSON.parse(#"{"value":3}"#)) == nil)
        #expect(await renderer.renderResult(toolCallId: "id", name: "custom", result: [], details: nil, isError: false) != nil)
    }

    @Test func registeredLookupIncludesBuiltInsCodemodeMcpAndExtensionSlots() async throws {
        var mcp = toolTestDefinition("mcp__server__tool")
        mcp.label = "server/tool"
        mcp.namespace = ToolNamespace(name: "mcp__server")
        var extensionTool = toolTestDefinition("extension_tool")
        extensionTool.renderCall = { _, _ in MainActor.assumeIsolated { F4THtmlLines(["extension call"]) } }
        extensionTool.renderResult = { _, _, _ in MainActor.assumeIsolated { F4THtmlLines(["extension result"]) } }
        var grepOverride = toolTestDefinition("grep")
        grepOverride.renderResult = { _, _, _ in MainActor.assumeIsolated { F4THtmlLines(["grep extension result"]) } }
        let codemode = toolTestDefinition("codemode")
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let hooks = [
            LoadedHook(path: "builtin:codemode", resolvedPath: "builtin:codemode", handlers: [:], tools: [codemode.name: codemode], isExtension: true),
            LoadedHook(path: "builtin:mcp", resolvedPath: "builtin:mcp", handlers: [:], tools: [mcp.name: mcp], isExtension: true),
            LoadedHook(path: "/tmp/f4t-extension.swift", resolvedPath: "/tmp/f4t-extension.swift", handlers: [:], tools: [extensionTool.name: extensionTool, grepOverride.name: grepOverride], isExtension: true),
        ]
        let runner = HookRunner(hooks, "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let renderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { registeredToolRenderers($0, session: session) })
        for name in ["grep", "find"] {
            let call = try #require(await renderer.renderCall(toolCallId: name, name: name, arguments: try OrderedJSON.parse(#"{"pattern":"needle","path":"/tmp"}"#)))
            #expect(call.contains("needle"))
            #expect(call.contains(name))
        }
        let grepResult = try #require(await renderer.renderResult(toolCallId: "grep", name: "grep", result: [], details: nil, isError: false))
        #expect(grepResult.expanded == ansiLinesToHtml(["grep extension result"]))
        let codeCall = try #require(await renderer.renderCall(toolCallId: "code", name: "codemode", arguments: try OrderedJSON.parse(#"{"code":"return 42"}"#)))
        #expect(codeCall.contains("codemode"))
        let mcpCall = try #require(await renderer.renderCall(toolCallId: "mcp", name: mcp.name, arguments: try OrderedJSON.parse(#"{"arg":"yes"}"#)))
        #expect(mcpCall.contains("server/tool"))
        #expect(mcpCall.contains("yes"))
        let output = (1...8).map { "line\($0)" }.joined(separator: "\n")
        let mcpResult = try #require(await renderer.renderResult(toolCallId: "mcp", name: mcp.name, result: [.text(TextContent(text: output))], details: nil, isError: false))
        #expect(mcpResult.collapsed?.contains("line5") == true)
        #expect(mcpResult.collapsed?.contains("line6") == false)
        #expect(mcpResult.expanded?.contains("line8") == true)
        #expect(await renderer.renderCall(toolCallId: "extension", name: extensionTool.name, arguments: try OrderedJSON.parse("{}")) == ansiLinesToHtml(["extension call"]))
        let customResult = try #require(await renderer.renderResult(toolCallId: "extension", name: extensionTool.name, result: [], details: nil, isError: false))
        #expect(customResult.expanded == ansiLinesToHtml(["extension result"]))
    }

    @Test func sendableAdapterSupportsConcurrentCallsFromBackgroundExecutor() async throws {
        let slots = ToolRenderers(renderCall: { args, _, context in
            let value = args["value"]?.value as? Int ?? -1
            context.state.values["value"] = value
            return F4THtmlLines(["call \(value)"])
        }, renderResult: { _, options, _, context in
            let value = context.args["value"]?.value as? Int ?? -1
            #expect(context.state.values["value"] as? Int == value)
            return F4THtmlLines(["\(options.expanded ? "expanded" : "collapsed") \(value)"])
        })
        let renderer: any ToolHtmlRenderer = TuiToolHtmlRenderer(theme: theme, cwd: "/tmp", getRenderers: { _ in slots })
        let results = await Task.detached {
            await withTaskGroup(of: (Int, String?, String?, String?).self) { group in
                for value in 0..<12 {
                    group.addTask {
                        let arguments = OrderedJSON.object([("value", .number(String(value)))])
                        let id = String(value)
                        let call = await renderer.renderCall(toolCallId: id, name: "custom", arguments: arguments)
                        let result = await renderer.renderResult(toolCallId: id, name: "custom", result: [], details: nil, isError: false)
                        return (value, call, result?.collapsed, result?.expanded)
                    }
                }
                var results: [(Int, String?, String?, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
        }.value
        #expect(results.count == 12)
        for (value, call, collapsed, expanded) in results {
            #expect(call == ansiLinesToHtml(["call \(value)"]))
            #expect(collapsed == ansiLinesToHtml(["collapsed \(value)"]))
            #expect(expanded == ansiLinesToHtml(["expanded \(value)"]))
        }
    }
}
