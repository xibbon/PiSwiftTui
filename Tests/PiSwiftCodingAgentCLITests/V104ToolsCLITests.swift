import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui
import Testing
@testable import PiSwiftCodingAgentCLI

private enum V104CLIError: Error { case missingExecutable }

private struct V104CLISelectionCase: Sendable {
    let arguments: [String]
    let registered: Set<String>?
    let active: Set<String>
    let allowed: Set<String>?
    let excluded: Set<String>
    let usesDefaults: Bool

    init(_ arguments: [String], registered: Set<String>? = nil, active: Set<String>,
         allowed: Set<String>? = nil, excluded: Set<String> = [], usesDefaults: Bool = false) {
        self.arguments = arguments
        self.registered = registered
        self.active = active
        self.allowed = allowed
        self.excluded = excluded
        self.usesDefaults = usesDefaults
    }
}

private let v104CLISelectionCases: [V104CLISelectionCase] = [
    .init([], active: ["read", "bash", "edit", "write", "review", "mcp__radius__direct"], usesDefaults: true),
    .init(["--tools", "read,codemode"],
          registered: ["read", "codemode", "mcp__radius__direct", "mcp__radius__search", LIST_MCP_RESOURCES_TOOL],
          active: ["read", "codemode"], allowed: ["read", "codemode"]),
    .init(["--tools", "re*"],
          registered: ["read", "review", "mcp__radius__direct", "mcp__radius__search", LIST_MCP_RESOURCES_TOOL],
          active: ["read", "review"], allowed: ["re*"]),
    .init(["--exclude-tools", "b*"],
          active: ["read", "edit", "write", "review", "mcp__radius__direct"], excluded: ["b*"], usesDefaults: true),
    .init(["--no-tools"], registered: [], active: [], allowed: []),
    .init(["--no-builtin-tools"], active: ["review", "mcp__radius__direct"]),
    .init(["--tools", ""], registered: [], active: [], allowed: []),
    .init(["--no-tools", "--tools", "read,codemode"],
          registered: ["read", "codemode", "mcp__radius__direct", "mcp__radius__search", LIST_MCP_RESOURCES_TOOL],
          active: ["read", "codemode"], allowed: ["read", "codemode"]),
    .init(["--tools", "read,codemode,mcp__radius__*"],
          registered: ["read", "codemode", "mcp__radius__direct", "mcp__radius__search"],
          active: ["read", "codemode", "mcp__radius__direct"], allowed: ["read", "codemode", "mcp__radius__*"]),
    .init(["--tools", "read,codemode", "--exclude-tools", "mcp__*"],
          registered: ["read", "codemode", LIST_MCP_RESOURCES_TOOL],
          active: ["read", "codemode"], allowed: ["read", "codemode"], excluded: ["mcp__*"])
]

private func v104CLITool(_ name: String, exposure: ToolExposure = .direct, defaultActive: Bool = true) -> CustomTool {
    CustomTool(name: name, label: name, description: name,
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable([String: AnyCodable]())],
        execute: { _, _, _, _, _ in CustomToolResult(content: [.text(TextContent(text: "ok"))]) },
        exposure: exposure, defaultActive: defaultActive)
}

@Suite("CLI v1.0.4 tools", .timeLimit(.minutes(1)))
struct V104ToolsCLITests {
    @Test func noMcpParses() throws {
        #expect(try !CLIOptions.parse([]).toArgs().noMcp)
        #expect(try CLIOptions.parse(["--no-mcp"]).toArgs().noMcp)
    }

    @Test func toolsKeepNamesPatternsAndNonemptyEntries() throws {
        // The shell removes quotes around mcp__radius__* before the CLI receives it.
        #expect(try CLIOptions.parse(["--tools", " read, codemode, mcp__radius__* , ,"])
            .toArgs().tools == ["read", "codemode", "mcp__radius__*"])
        #expect(try CLIOptions.parse(["--tools", "re*"]).toArgs().tools == ["re*"])
        #expect(try CLIOptions.parse(["--tools", ""]).toArgs().tools == [])
        #expect(try CLIOptions.parse(["--exclude-tools", " b*, mcp__* , ,"])
            .toArgs().excludeTools == ["b*", "mcp__*"])
    }

    @Test(arguments: [false, true])
    func noMcpOverridesSettingsAndExplicitPath(_ noExtensions: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-mcp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var values = Settings()
        values.extensions = ["+builtin:mcp"]
        let settings = SettingsManager.inMemory(values)
        let resolved = try await resolveBuiltinExtensionPaths(settingsManager: settings,
            names: builtInExtensions.map(\.name), cwd: directory.path, agentDir: directory.path, projectTrusted: true)
        let disabledPaths = Set(resolved.extensions.filter { !$0.enabled }.map { "-" + $0.path })
        let replacement = InlineExtension(name: "mcp") { _ in }
        let selected = selectStartupInlineExtensions(builtInExtensions + [replacement],
            disabledPaths: disabledPaths, explicitPaths: ["builtin:mcp"], noExtensions: noExtensions, noMcp: true)
        #expect(!selected.contains { $0.builtin && $0.name == "mcp" })
        #expect(selected.contains { !$0.builtin && $0.name == "mcp" })
        let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(
            cwd: directory.path, agentDir: directory.path, settingsManager: settings,
            additionalExtensionPaths: ["builtin:mcp"], noExtensions: noExtensions,
            builtinExtensions: builtInExtensions.map(\.name), disabledBuiltinExtensions: ["mcp"], offline: true))
        await loader.reload()
        #expect(!loader.getExtensions().paths.contains("builtin:mcp"))
        await loader.reload()
        #expect(!loader.getExtensions().paths.contains("builtin:mcp"))
    }

    @Test(arguments: v104CLISelectionCases)
    fileprivate func startupMatchesSdk(_ test: V104CLISelectionCase) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-selection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let args = try CLIOptions.parse(test.arguments).toArgs()
        let settings = SettingsManager.inMemory()
        let custom = v104CLITool("review")
        let extensionTools = [
            v104CLITool("codemode", defaultActive: false),
            v104CLITool("mcp__radius__direct"),
            v104CLITool("mcp__radius__search", exposure: .deferred, defaultActive: false),
            v104CLITool(LIST_MCP_RESOURCES_TOOL, exposure: .codemode, defaultActive: false)
        ]
        let registered = ToolName.allCases.map { InitialToolRegistration(name: $0.rawValue, isBuiltin: true) }
            + ([custom] + extensionTools).map {
                InitialToolRegistration(name: $0.name, exposure: $0.exposure ?? .direct, defaultActive: $0.defaultActive ?? true)
            }
        let selected = selectStartupTools(args, registeredTools: registered, settingsManager: settings)
        let expectedRegistry = test.registered ?? Set(registered.map(\.name)).subtracting(test.excluded.contains("b*") ? ["bash"] : [])
        #expect(Set(selected.initial.registeredToolNames) == expectedRegistry)
        #expect(Set(selected.initial.activeToolNames) == test.active)
        #expect(selected.allowedToolNames == test.allowed)
        #expect(selected.excludedToolNames == test.excluded)
        #expect(selected.usesDefaultTools == test.usesDefaults)

        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
        // The order keeps the CLI's four fallback tools. The SDK also defaults to subagent.
        var sdkDefaults = Settings()
        sdkDefaults.defaultTools = ["read", "bash", "edit", "write"]
        let sdk = try await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path, authStorage: auth, model: model, offline: true,
            toolNames: args.tools, excludeTools: args.excludeTools,
            noTools: args.noTools == true ? .all : (args.noBuiltinTools == true ? .builtin : nil),
            customTools: [CustomToolDefinition(tool: custom)], hooks: [],
            inlineExtensions: [InlineExtension(name: "fixture") { api in
                for tool in extensionTools { api.registerTool(tool) }
            }], sessionManager: .inMemory(), settingsManager: .inMemory(sdkDefaults)))
        defer { sdk.session.dispose() }
        #expect(sdk.diagnostics.filter { $0.type == "error" }.isEmpty)
        #expect(Set(sdk.session.getAllToolNames()) == Set(selected.initial.registeredToolNames))
        #expect(Set(sdk.session.getActiveToolNames()) == Set(selected.initial.activeToolNames))
    }

    @Test func defaultSettingsCanSelectAnInactiveExtensionAndPreserveOrder() {
        var values = Settings()
        values.defaultTools = ["codemode", "write", "read"]
        let selected = selectStartupTools(Args(), registeredTools: [
            InitialToolRegistration(name: "read", isBuiltin: true),
            InitialToolRegistration(name: "write", isBuiltin: true),
            InitialToolRegistration(name: "codemode", exposure: .modelOnly, defaultActive: false)
        ], settingsManager: .inMemory(values))
        #expect(selected.initial.activeToolNames == ["codemode", "write", "read"])
        #expect(selected.usesDefaultTools)
    }

    @Test func helpIncludesPatternsMcpAndExample() {
        let help = (PiCodingAgentCLI.helpMessage() + CLIOptions.helpMessage())
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("Comma-separated allowlist of tool names or patterns (*) to enable"))
        #expect(help.contains("Keeps MCP tools unless an entry starts with mcp__"))
        #expect(help.contains("Comma-separated denylist of tool names or patterns (*) to disable"))
        #expect(help.contains("Applies to all tools, MCP tools included"))
        #expect(help.contains("--no-mcp"))
        #expect(help.contains("Disable built-in MCP support: no servers connect and no MCP tools"))
        #expect(help.contains("# Codemode with only the tools of one MCP server"))
        #expect(help.contains("--tools read,bash,codemode,'mcp__radius__*'"))
    }

    @Test func arbitraryToolsProduceNoWarning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t1-parse-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binaryDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [binaryDirectory.appendingPathComponent("pi-coding-agent"),
            repo.appendingPathComponent(".build/debug/pi-coding-agent"),
            repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent")]
        let process = Process()
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw V104CLIError.missingExecutable
        }
        process.executableURL = executable
        process.arguments = ["--tools", "read,codemode,mcp__radius__*", "--list-models", "t1-no-model-match", "--offline"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment[ENV_AGENT_DIR] = directory.path
        process.environment = environment
        let error = Pipe()
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).isEmpty)
    }
}
