import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

@Suite("PT3b CLI session factory")
struct PT3bSessionFactoryTests {
    @Test func firstAndReplacementUseCwdBoundToolsAndWarmers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt3b-factory-\(UUID())")
        let firstCwd = root.appendingPathComponent("first")
        let nextCwd = root.appendingPathComponent("next")
        let sessionDir = root.appendingPathComponent("sessions")
        for directory in [firstCwd, nextCwd, sessionDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "first file".write(to: firstCwd.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try "next file".write(to: nextCwd.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        var parsed = Args()
        parsed.noExtensions = true
        parsed.noSkills = true
        parsed.offline = true

        let streamCalls = LockedState<[String]>([])
        func make(_ cwd: URL, replacement: Bool, marker: String) async throws -> CLISessionBundle {
            let settings = SettingsManager.inMemory()
            let auth = AuthStorage.inMemory(["pt3b": .apiKey(ApiKeyCredential(key: "test"))])
            let policy = CLIClientIdentityPolicy(settings)
            let registry = ModelRegistry(auth, root.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
            registry.registerProvider(HookProviderConfig(provider: "pt3b", api: .openAICompletions,
                baseUrl: "https://provider.invalid", streamSimple: { model, _, _ in
                    streamCalls.withLock { $0.append(marker) }
                    let stream = AssistantMessageEventStream()
                    stream.end(AssistantMessage(content: [.text(TextContent(text: marker))],
                        api: model.api, provider: model.provider, model: model.id,
                        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                        stopReason: .stop))
                    return stream
                }, models: [HookProviderModel(id: "test")]), sourceId: marker)
            let model = try #require(registry.find("pt3b", "test"))
            let manager = SessionManager.create(cwd.path, sessionDir.path)
            return try await buildCLISession(cwd: cwd.path, agentDir: root.path,
                sessionManager: manager, parsed: parsed, extensions: [], settingsManager: settings,
                projectTrusted: true, authStorage: auth, modelRegistry: registry,
                clientIdentityPolicy: policy, eventBus: createEventBus(), scopedModels: [],
                initialModel: model, initialThinking: .off,
                sessionContext: manager.buildSessionContext(), shouldPrintMessages: false,
                isInteractive: false, resolvedOffline: true, isReplacement: replacement)
        }

        let first = try await make(firstCwd, replacement: false, marker: "first stream")
        let next = try await make(nextCwd, replacement: true, marker: "next stream")
        defer { first.session.dispose(); next.session.dispose() }
        #expect(first.session.cacheWarmer != nil)
        #expect(next.session.cacheWarmer != nil)
        #expect(first.session.cacheWarmer !== next.session.cacheWarmer)
        #expect(first.session.getCurrentSystemPromptOptions().cwd == firstCwd.path)
        #expect(next.session.getCurrentSystemPromptOptions().cwd == nextCwd.path)
        for (bundle, expected) in [(first, "first file"), (next, "next file")] {
            let read = try #require(bundle.session.agent.state.tools.first { $0.name == "read" })
            let result = try await read.execute("pt3b-read", ["path": AnyCodable("sample.txt")], nil, nil)
            #expect(result.content.contains {
                if case .text(let text) = $0 { return text.text.contains(expected) }
                return false
            })
        }
        try await first.session.prompt("use first stream")
        try await next.session.prompt("use next stream")
        #expect(streamCalls.withLock { $0 } == ["first stream", "next stream"])
        for (bundle, marker) in [(first, "first stream"), (next, "next stream")] {
            #expect(bundle.session.agent.state.messages.contains {
                if case .assistant(let message) = $0 {
                    return message.content.contains {
                        if case .text(let text) = $0 { return text.text == marker }
                        return false
                    }
                }
                return false
            })
        }
    }
}
