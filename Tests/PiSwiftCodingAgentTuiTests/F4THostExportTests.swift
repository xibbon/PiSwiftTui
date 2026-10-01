import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private let f4tHostCallID = "f4t-host-call"
private let f4tHostToolName = "f4t_custom_tool"

private struct F4THostSession {
    let session: AgentSession
    let directory: URL

    @MainActor
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-f4t-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tool = toolTestDefinition(f4tHostToolName)
        tool.renderCall = { _, _ in
            MainActor.assumeIsolated { Text("F4T custom call", paddingX: 0, paddingY: 0) }
        }
        tool.renderResult = { _, options, _ in
            MainActor.assumeIsolated {
                Text(options.expanded ? "F4T expanded result" : "F4T collapsed result", paddingX: 0, paddingY: 0)
            }
        }
        let manager = SessionManager.create(directory.path, directory.appendingPathComponent("sessions").path)
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: f4tHostCallID, name: f4tHostToolName, arguments: [:]))],
            api: .openAIResponses, provider: "test", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse
        )))
        manager.appendMessage(.toolResult(ToolResultMessage(
            toolCallId: f4tHostCallID, toolName: f4tHostToolName,
            content: [.text(TextContent(text: "plain fallback result"))], isError: false
        )))
        let settings = SettingsManager.inMemory()
        session = AgentSession(config: AgentSessionConfig(
            agent: Agent(), sessionManager: manager, settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path, settingsManager: settings)),
            customTools: [LoadedCustomTool(path: "<f4t>", resolvedPath: "<f4t>", tool: tool)],
            modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false),
            toolDefinitions: [f4tHostToolName: tool]
        ))
    }

    func cleanup() {
        session.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func f4tHostPayload(_ path: String) throws -> OrderedJSON {
    let html = try String(contentsOfFile: path, encoding: .utf8)
    let regex = try NSRegularExpression(pattern: #"<script id="session-data" type="application/json">([^<]+)</script>"#)
    let match = try #require(regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
    let encoded = (html as NSString).substring(with: match.range(at: 1))
    let data = try #require(Data(base64Encoded: encoded))
    return try OrderedJSON.parse(String(decoding: data, as: UTF8.self))
}

private func f4tExpectCustomHtml(_ payload: OrderedJSON) throws {
    let tool = try #require(payload["renderedTools"]?[f4tHostCallID])
    #expect(tool["callHtml"]?.stringValue?.contains("F4T custom call") == true)
    #expect(tool["resultHtmlCollapsed"]?.stringValue?.contains("F4T collapsed result") == true)
    #expect(tool["resultHtmlExpanded"]?.stringValue?.contains("F4T expanded result") == true)
    #expect(tool["resultHtmlExpanded"]?.stringValue?.contains("plain fallback result") == false)
}

@MainActor @Suite(.serialized) struct F4THostExportTests {
    @Test func interactiveExportCommandUsesInstalledDefault() async throws {
        let fixture = try F4THostSession()
        defer { fixture.cleanup() }
        #expect(fixture.session.toolHtmlRenderer == nil)
        let mode = InteractiveMode(session: fixture.session, version: "f4t-test")
        #expect(fixture.session.toolHtmlRenderer != nil)
        let path = fixture.directory.appendingPathComponent("interactive.html").path
        await mode.handleExportCommand("/export \(path)")
        try f4tExpectCustomHtml(f4tHostPayload(path))
        #expect(mode.chatContainer.render(width: 100).joined().contains("Exported to:"))
    }

    @Test func printHostInstallsDefaultBeforeSessionExport() async throws {
        let fixture = try F4THostSession()
        defer {
            restoreStdoutAfterMachineReadableOutput()
            fixture.cleanup()
        }
        #expect(fixture.session.toolHtmlRenderer == nil)
        try await runPrintMode(fixture.session, .text, [])
        restoreStdoutAfterMachineReadableOutput()
        #expect(fixture.session.toolHtmlRenderer != nil)
        let path = fixture.directory.appendingPathComponent("print.html").path
        _ = try await fixture.session.exportToHtml(path)
        try f4tExpectCustomHtml(f4tHostPayload(path))
    }

    @Test func rpcHostExportCommandUsesInstalledDefault() async throws {
        let fixture = try F4THostSession()
        defer { fixture.cleanup() }
        #expect(fixture.session.toolHtmlRenderer == nil)
        let path = fixture.directory.appendingPathComponent("rpc.html").path
        let command = try JSONSerialization.data(withJSONObject: ["type": "export_html", "id": "f4t-export", "outputPath": path])
        let lines = LockedState([String(decoding: command, as: UTF8.self)])
        let responses = LockedState<[[String: AnyCodable]]>([])
        await runRpcMode(fixture.session,
            output: RpcOutput(write: { response in responses.withLock { $0.append(response.mapValues(AnyCodable.init)) } }),
            readInputLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } })
        #expect(fixture.session.toolHtmlRenderer != nil)
        #expect(responses.withLock { $0.first?["success"]?.value as? Bool } == true)
        try f4tExpectCustomHtml(f4tHostPayload(path))
    }

    @Test func shareExportsWithHostDefaultBeforeLocalUpload() async throws {
        let fixture = try F4THostSession()
        defer { fixture.cleanup() }
        let mode = InteractiveMode(session: fixture.session, version: "f4t-test")
        #expect(fixture.session.toolHtmlRenderer != nil)
        let payloads = LockedState<[OrderedJSON]>([])
        let errors = LockedState<[String]>([])
        let statuses = LockedState<[String]>([])
        // Keep the real export closure. The local runner reads the file in place of gh.
        let dependencies = SessionShareDependencies(runGH: { arguments, _ in
            if arguments.first == "gist" {
                let path = try #require(arguments.last)
                let payload = try f4tHostPayload(path)
                payloads.withLock { $0.append(payload) }
            }
            return ExecResult(stdout: "https://gist.github.com/test/f4t\n", stderr: "", code: 0, killed: false)
        })
        let tui = TUI(terminal: ToolTestTerminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        let container = Container()
        container.addChild(editor)
        await shareSession(session: fixture.session, tui: tui, editorContainer: container, editor: editor,
            showStatus: { value in statuses.withLock { $0.append(value) } },
            showError: { value in errors.withLock { $0.append(value) } }, dependencies: dependencies)
        try f4tExpectCustomHtml(#require(payloads.withLock { $0.first }))
        #expect(errors.withLock { $0.isEmpty })
        #expect(statuses.withLock { $0.contains(where: { $0.contains("Share URL:") }) })
        withExtendedLifetime(mode) {}
    }
}
