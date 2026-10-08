import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private func v110Parse(_ arguments: [String]) throws -> Args {
    try CLIOptions.parse(PiCodingAgentCLI.preprocessArguments(arguments)).toArgs()
}

private func v110Tool(_ name: String, defaultActive: Bool = true) -> CustomTool {
    CustomTool(name: name, label: name, description: name, parameters: [:],
        execute: { _, _, _, _, _ in CustomToolResult(content: []) }, defaultActive: defaultActive)
}

private struct V110SelectionCase: Sendable {
    let arguments: [String]
    var defaults: [String] = ["read", "bash", "edit", "write"]
    let active: Set<String>
}

private let v110SelectionCases: [V110SelectionCase] = [
    .init(arguments: ["-t", "+codemode,-write"], active: ["read", "bash", "edit", "codemode", "review"]),
    .init(arguments: ["--no-builtin-tools", "--tools", "+grep"], active: ["grep", "review"]),
    .init(arguments: ["--no-tools", "--tools", "+review"], active: ["review"]),
    .init(arguments: ["--tools", "+codemode,-write"], defaults: ["+grep"],
          active: ["read", "bash", "edit", "grep", "codemode", "review"]),
    .init(arguments: ["--tools", "+grep,-bash", "--exclude-tools", "gr*"], active: ["read", "edit", "write", "review"]),
    .init(arguments: ["--tools", "re*", "--exclude-tools", "review"], active: ["read"]),
    .init(arguments: ["-nt", "-nbt", "-t", "+grep"], active: ["grep"]),
]

@Suite("CLI v1.1.0 tools")
struct V110ToolsCLITests {
    @Test func modifiersAndDashValuesParse() throws {
        for flag in ["--tools", "-t"] {
            #expect(try v110Parse([flag, " \n+codemode, -write , ,\n"]).tools == ["+codemode", "-write"])
            #expect(try v110Parse([flag, "-write"]).tools == ["-write"])
            #expect(try v110Parse([flag, "-nt"]).tools == ["-nt"])
            #expect(try v110Parse([flag, "--mode"]).tools == ["--mode"])
            #expect(PiCodingAgentCLI.modeArgumentError([flag, "--mode"]) == nil)
        }
        #expect(try CLIOptions.parse(["-t", "-write"]).toArgs().tools == ["-write"])
        #expect(try v110Parse(["--tools=-write"]).tools == ["-write"])
        #expect(PiCodingAgentCLI.preprocessArguments(["-t", "mcp"]) == ["--tools", "mcp"])
        #expect(PiCodingAgentCLI.preprocessArguments(["-xt", "mcp"]) == ["--exclude-tools", "mcp"])
        for flag in ["--exclude-tools", "-xt"] {
            #expect(try v110Parse([flag, "-x"]).excludeTools == ["-x"])
            #expect(try v110Parse([flag, "-nt"]).excludeTools == ["-nt"])
        }
        #expect(try v110Parse(["-nt"]).noTools == true)
        #expect(try v110Parse(["-nbt"]).noBuiltinTools == true)
    }

    @Test func rawCheckKeepsFlagAndUpstreamProblemText() {
        #expect(PiCodingAgentCLI.toolsArgumentError(["--tools", "read,+codemode"]) ==
                "--tools: tool names cannot be mixed with +name or -name entries")
        #expect(PiCodingAgentCLI.toolsArgumentError(["-t", "+mcp__radius__*"]) ==
                "-t: +name and -name entries take exact tool names, not patterns: +mcp__radius__*")
        #expect(PiCodingAgentCLI.toolsArgumentError(["--tools=read,+codemode"]) ==
                "--tools: tool names cannot be mixed with +name or -name entries")
        #expect(PiCodingAgentCLI.toolsArgumentError(["-t", " +codemode, -write , ,"]) == nil)
        #expect(PiCodingAgentCLI.toolsArgumentError(["--tools", "-write"]) == nil)
        #expect(PiCodingAgentCLI.toolsArgumentError(["--", "-t", "+*"]) == nil)
        #expect(PiCodingAgentCLI.toolsArgumentError(["--system-prompt", "--tools", "read,+codemode"]) == nil)
        #expect(PiCodingAgentCLI.toolsArgumentError(["--exclude-tools", "-t", "+*"]) == nil)
        #expect(PiCodingAgentCLI.toolsArgumentError(["--tools"]) == nil)
    }

    @Test func invalidListsExitOneWithExactStderr() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([
            directory.appendingPathComponent("pi-coding-agent"),
            repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent"),
            repo.appendingPathComponent(".build/debug/pi-coding-agent"),
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) })
        for (arguments, problem) in [
            (["--tools", "read,+codemode"], "--tools: tool names cannot be mixed with +name or -name entries"),
            (["-t", "+mcp__radius__*"], "-t: +name and -name entries take exact tool names, not patterns: +mcp__radius__*"),
        ] {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let error = Pipe()
            process.standardError = error
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 1)
            #expect(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "Error: \(problem)\n")
        }
    }

    @Test func helpIncludesModifierLineExampleAndAliases() {
        let help = PiCodingAgentCLI.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("Only +name/-name entries add to or remove from the defaults"))
        #expect(help.contains("# Add codemode to the default tools"))
        #expect(help.contains("--tools +codemode"))
        #expect(help.contains("--tools, -t <tools>"))
        #expect(help.contains("--no-tools, -nt"))
        #expect(help.contains("--no-builtin-tools, -nbt"))
    }

    @Test(arguments: v110SelectionCases)
    fileprivate func startupMatchesSdk(_ test: V110SelectionCase) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v110-cli-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let args = try v110Parse(test.arguments)
        var values = Settings()
        values.defaultTools = test.defaults
        let settings = SettingsManager.inMemory(values)
        let custom = v110Tool("review")
        let codemode = v110Tool("codemode", defaultActive: false)
        let registered = ToolName.allCases.map { InitialToolRegistration(name: $0.rawValue, isBuiltin: true) } + [
            InitialToolRegistration(name: "review"), InitialToolRegistration(name: "codemode", defaultActive: false)
        ]
        let selected = selectStartupTools(args, registeredTools: registered, settingsManager: settings)
        #expect(Set(selected.initial.activeToolNames) == test.active)
        #expect(selected.allowedToolNames == selected.initial.allowedToolNames)
        #expect(selected.usesDefaultTools == selected.initial.usesDefaultTools)
        #expect(selected.defaultToolModifiers == selected.initial.defaultToolModifiers ?? [])
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
        let sdk = try await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path, authStorage: auth, model: model, offline: true,
            toolNames: args.tools, excludeTools: args.excludeTools,
            noTools: args.noTools == true ? .all : (args.noBuiltinTools == true ? .builtin : nil),
            customTools: [CustomToolDefinition(tool: custom)], hooks: [],
            inlineExtensions: [InlineExtension(name: "fixture") { api in api.registerTool(codemode) }],
            sessionManager: .inMemory(), settingsManager: settings))
        defer { sdk.session.dispose() }
        #expect(sdk.diagnostics.filter { $0.type == "error" }.isEmpty)
        #expect(Set(sdk.session.getAllToolNames()) == Set(selected.initial.registeredToolNames))
        #expect(Set(sdk.session.getActiveToolNames()) == test.active)
    }

    @Test func cliConfigKeepsRemovedBashAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v110-cli-reload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        try #"{"defaultTools":["read"]}"#.write(to: path, atomically: true, encoding: .utf8)
        let settings = SettingsManager.create(directory.path, directory.path)
        let tools = createAllTools(cwd: directory.path)
        let selected = selectStartupTools(try v110Parse(["-t", "-bash,+grep"]),
            registeredTools: ToolName.allCases.map { InitialToolRegistration(name: $0.rawValue, isBuiltin: true) },
            settingsManager: settings)
        let registry = Dictionary(uniqueKeysWithValues: tools.map { ($0.key.rawValue, $0.value) })
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let agent = Agent(AgentOptions(initialState: AgentState(model: model,
            tools: selected.initial.activeToolNames.compactMap { registry[$0] })))
        let session = AgentSession(config: AgentSessionConfig(
            agent: agent, sessionManager: .inMemory(directory.path), settingsManager: settings,
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path, agentDir: directory.path,
                settingsManager: settings, noExtensions: true, offline: true)),
            modelRegistry: ModelRegistry(AuthStorage.inMemory()),
            usesDefaultTools: selected.usesDefaultTools, defaultToolModifiers: selected.defaultToolModifiers,
            excludedToolNames: selected.excludedToolNames, allowedToolNames: selected.allowedToolNames,
            toolRegistry: registry, toolRegistryOrder: selected.initial.registeredToolNames))
        defer { session.dispose() }
        #expect(Set(session.getActiveToolNames()) == ["read", "grep"])
        try #"{"defaultTools":["read","bash","edit"]}"#.write(to: path, atomically: true, encoding: .utf8)
        await session.reload()
        await session.reloadExtensions()
        #expect(Set(session.getActiveToolNames()) == ["read", "grep", "edit"])
        #expect(!session.getActiveToolNames().contains("bash"))
    }
}
