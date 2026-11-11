import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private func pt1MarkdownRunner(_ seen: LockedState<[MarkdownTransformContext]>) -> HookRunner {
    let manager = SessionManager.inMemory("/tmp")
    let registry = ModelRegistry(AuthStorage.inMemory(), nil,
        modelsStore: InMemoryModelsStore(), networkEnabled: false)
    let first = LoadedHook(path: "first", resolvedPath: "first", handlers: [:],
        markdownTransformers: [{ source, context in
            seen.withLock { $0.append(context) }
            return source + " first"
        }])
    let second = LoadedHook(path: "second", resolvedPath: "second", handlers: [:],
        markdownTransformers: [{ source, _ in source + " second" }])
    return HookRunner([first, second], "/tmp", manager, registry)
}

@MainActor @Suite(.serialized)
struct PT1MarkdownTests {
    // v1.5.2 PT1: assistant-message.test.ts:228, input-transform-streaming-example.test.ts.
    @Test func chainsTransformersAndPassesPersistedAssistantMetadata() {
        let seen = LockedState<[MarkdownTransformContext]>([])
        let runner = pt1MarkdownRunner(seen)
        let message = AssistantMessage(content: [.text(TextContent(text: "answer")),
            .thinking(ThinkingContent(thinking: "reason"))],
            api: .anthropicMessages, provider: "anthropic", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop)
        let row = AssistantMessageComponent(message: message, markdownRunner: runner,
            messageId: "entry-1", messageTimestamp: "2026-11-11T12:00:00.000Z")
        let output = toolTestText(row)
        #expect(output.contains("answer first second"))
        #expect(output.contains("reason first second"))
        let contexts = seen.withLock { $0 }
        #expect(contexts.contains { $0.messageType == .assistant && $0.messageId == "entry-1" &&
            $0.timestamp == "2026-11-11T12:00:00.000Z" && $0.availableWidth > 0 && !$0.isStreaming })
        #expect(contexts.contains { $0.messageType == .assistantThinking })
    }

    // v1.5.2 PT1: assistant-message.test.ts:228 streaming transition.
    @Test func liveAssistantHasNoPersistedMetadataAndChangesStreamingState() {
        let seen = LockedState<[MarkdownTransformContext]>([])
        let runner = pt1MarkdownRunner(seen)
        let message = AssistantMessage(content: [.text(TextContent(text: "answer"))],
            api: .anthropicMessages, provider: "anthropic", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop)
        let row = AssistantMessageComponent(message: message, isStreaming: true, markdownRunner: runner)
        _ = row.render(width: 80)
        row.setStreaming(false)
        _ = row.render(width: 80)
        let contexts = seen.withLock { $0 }
        #expect(contexts.contains { $0.messageType == .assistant && $0.isStreaming && $0.messageId == nil && $0.timestamp == nil })
        #expect(contexts.contains { $0.messageType == .assistant && !$0.isStreaming })
    }

    // v1.5.2 PT1: custom-message.test.ts and mermaid.test.ts summary surface.
    @Test func userCustomSkillAndSummaryUseTheirOwnSurfaces() {
        let seen = LockedState<[MarkdownTransformContext]>([])
        let runner = pt1MarkdownRunner(seen)
        #expect(toolTestText(UserMessageComponent(text: "user", markdownRunner: runner,
            messageId: "user-1", messageTimestamp: "2026-11-11T12:00:00.000Z")).contains("user first second"))
        #expect(toolTestText(HookMessageComponent(message: HookMessage(customType: "note",
            content: .text("custom"), display: true), markdownRunner: runner)).contains("custom first second"))
        let skill = SkillInvocationMessageComponent(skillBlock: ParsedSkillBlock(name: "test",
            location: "/tmp/test", content: "skill body"), markdownRunner: runner)
        skill.setExpanded(true)
        #expect(toolTestText(skill).contains("skill body first second"))
        let summary = BranchSummaryMessageComponent(message: BranchSummaryMessage(summary: "summary body", timestamp: 0),
            markdownRunner: runner, messageId: "branch-1", messageTimestamp: "2026-11-11T12:01:00.000Z")
        summary.setExpanded(true)
        let output = toolTestText(summary)
        #expect(output.contains("summary body first second"))
        #expect(!output.contains("Branch Summary first second"))
        let contexts = seen.withLock { $0 }
        #expect(contexts.contains { $0.messageType == .user && $0.messageId == "user-1" })
        #expect(contexts.filter { $0.messageType == .custom }.count >= 2)
        #expect(contexts.contains { $0.messageType == .summary && $0.messageId == "branch-1" })
    }

    // v1.5.2 PT1: interactive-mode-extension-changelog.test.ts:220,228.
    @Test func changelogUsesChangelogSurface() {
        let seen = LockedState<[MarkdownTransformContext]>([])
        let runner = pt1MarkdownRunner(seen)
        let session = AgentSession(config: AgentSessionConfig(agent: Agent(),
            sessionManager: .inMemory("/tmp"), settingsManager: .inMemory(),
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: "/tmp", settingsManager: .inMemory())),
            hookRunner: runner,
            modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil,
                modelsStore: InMemoryModelsStore(), networkEnabled: false)))
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: VERSION)
        #expect(toolTestText(mode.changelogMarkdownComponent("release", paddingY: 0)).contains("release first second"))
        #expect(seen.withLock { $0 }.contains { $0.messageType == .changelog && $0.messageId == nil })
    }

    // v1.5.2 PT1: assistant-message.test.ts:127.
    @Test func emptyHiddenThinkingLabelAddsNoRows() {
        let message = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "secret"))],
            api: .anthropicMessages, provider: "anthropic", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop)
        let row = AssistantMessageComponent(message: message, hideThinkingBlock: true, hiddenThinkingLabel: "")
        #expect(row.render(width: 80).isEmpty)
    }
}
