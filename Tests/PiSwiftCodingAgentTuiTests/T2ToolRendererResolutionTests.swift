import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private struct T2RendererSession {
    let directory: URL
    let session: AgentSession

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-t2-renderers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager.create(directory.path, directory.appendingPathComponent("sessions").path)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let extensionHook = try #require(ExtensionLoader.load(createMcpExtension(options: McpExtensionOptions(
            loadConfig: { _ in LoadedMcpConfig() })), cwd: directory.path, eventBus: createEventBus()).hook)
        let runner = HookRunner([extensionHook], directory.path, manager, registry)
        session = t3aSession(manager: manager, registry: registry, runner: runner)
    }

    func cleanup() {
        session.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor @Suite(.serialized)
struct T2ToolRendererResolutionTests {
    // Upstream regression #10285: resumed MCP calls must render before connection.
    @Test func rendersUnregisteredMcpCallsThroughTheLibraryResolver() throws {
        let fixture = try T2RendererSession()
        defer { fixture.cleanup() }
        let name = "mcp__my_docs__search"
        let value = try #require(resolvedToolRenderers(name, session: fixture.session))
        let render = try #require(value.renderCall)
        let args = ["query": AnyCodable("pi")]
        #expect(toolTestText(try render(args, theme, ToolRenderContext(args: args, expanded: false)))
            .contains(#"my_docs/search query="pi""#))
        #expect(resolvedToolRenderers("not_mcp", session: fixture.session) == nil)
        var read = toolTestDefinition("read")
        read.renderCall = { _, _ in MainActor.assumeIsolated { Text("custom read call", paddingX: 0, paddingY: 0) } }
        let readRenderers = try #require(resolvedToolRenderers("read", session: fixture.session, fallback: read))
        let renderRead = try #require(readRenderers.renderCall)
        #expect(toolTestText(try renderRead([:], theme, ToolRenderContext())) == "custom read call")
        let row = ToolExecutionComponent(toolName: name, toolCallId: "call-1", args: args,
            renderers: value, ui: TUI(terminal: ToolTestTerminal()))
        #expect(toolTestText(row).contains(#"my_docs/search query="pi""#))
    }

    @Test func exportsUnregisteredMcpCallsWithTheInstalledHtmlRenderer() async throws {
        let fixture = try T2RendererSession()
        defer { fixture.cleanup() }
        let manager = fixture.session.sessionManager
        manager.appendMessage(.user(UserMessage(content: .text("search"), timestamp: 1)))
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: "call-1", name: "mcp__my_docs__search", arguments: ["query": AnyCodable("pi")]))],
            api: .openAIResponses, provider: "test", model: "test", usage: t3aUsage(), stopReason: .toolUse, timestamp: 2)))
        installDefaultToolHtmlRenderer(fixture.session)
        let path = fixture.directory.appendingPathComponent("export.html").path
        _ = try await fixture.session.exportToHtml(path)
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"<script id="session-data" type="application/json">([^<]+)</script>"#)
        let match = try #require(pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
        let data = try #require(Data(base64Encoded: (html as NSString).substring(with: match.range(at: 1))))
        let payload = try OrderedJSON.parse(String(decoding: data, as: UTF8.self))
        let call = try #require(payload["renderedTools"]?["call-1"]?["callHtml"]?.stringValue)
        #expect(call.contains("my_docs/search"))
        #expect(call.contains("query="))
        #expect(call.contains("pi"))
    }

    @Test func appliesResolvedOwnSlotsAfterTheMcpFamilyInLoadOrder() throws {
        let calls = LockedState<[String]>([])
        var definition = toolTestDefinition("registered")
        definition.renderCall = { _, _ in MainActor.assumeIsolated { Text("definition call", paddingX: 0, paddingY: 0) } }
        let first: ToolRendererResolver = { _, next in
            calls.withLock { $0.append("first") }
            var value = next()
            value?.renderResult = { _, _, _ in MainActor.assumeIsolated { Text("resolved result", paddingX: 0, paddingY: 0) } }
            return value
        }
        let second: ToolRendererResolver = { _, _ in
            calls.withLock { $0.append("second") }
            return CustomToolRenderers(renderShell: .self,
                renderCall: { _, _ in MainActor.assumeIsolated { Text("resolved call", paddingX: 0, paddingY: 0) } },
                builtIn: .mcp(label: "family/tool"))
        }
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let hooks = [
            LoadedHook(path: "first", resolvedPath: "first", handlers: [:], tools: [definition.name: definition],
                toolRenderers: [first], isExtension: true),
            LoadedHook(path: "second", resolvedPath: "second", handlers: [:], toolRenderers: [second], isExtension: true),
        ]
        let session = t3aSession(manager: manager, registry: registry, runner: HookRunner(hooks, "/tmp", manager, registry))
        defer { session.dispose() }
        let value = try #require(registeredToolRenderers("registered", session: session))
        #expect(calls.withLock { $0 } == ["first", "second"])
        #expect(value.renderShell == .self)
        let call = try #require(value.renderCall)
        let result = try #require(value.renderResult)
        #expect(toolTestText(try call([:], theme, ToolRenderContext())) == "resolved call")
        #expect(toolTestText(try result(AgentToolResult(content: []), RenderResultOptions(expanded: false, isPartial: false),
            theme, ToolRenderContext())) == "resolved result")
    }

    @Test func keepsHostBuiltInsInTheResolverBaseAndAllowsNilSuppression() throws {
        let resolver: ToolRendererResolver = { name, next in
            if name == "read" { return nil }
            guard next() != nil else { return nil }
            return CustomToolRenderers(renderResult: { _, _, _ in
                MainActor.assumeIsolated { Text("result override", paddingX: 0, paddingY: 0) }
            })
        }
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let hook = LoadedHook(path: "override", resolvedPath: "override", handlers: [:], toolRenderers: [resolver], isExtension: true)
        let session = t3aSession(manager: manager, registry: registry, runner: HookRunner([hook], "/tmp", manager, registry))
        defer { session.dispose() }
        #expect(resolvedToolRenderers("read", session: session) == nil)
        #expect(resolvedToolRenderers("unknown", session: session) == nil)
        let edit = try #require(resolvedToolRenderers("edit", session: session))
        #expect(edit.renderShell == .self)
        #expect(edit.renderCall != nil)
        #expect(edit.renderResult != nil)
    }
}
