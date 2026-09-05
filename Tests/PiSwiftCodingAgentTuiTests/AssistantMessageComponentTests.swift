import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private func makeAssistantMessage(content: [ContentBlock]) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .anthropicMessages,
        provider: "anthropic",
        model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
}

@MainActor
@Test func consecutiveThinkingBlocksRenderAsSingleMarkdownSection() throws {
    initTheme("dark")
    let component = AssistantMessageComponent(message: makeAssistantMessage(content: [
        .thinking(ThinkingContent(thinking: "first thought")),
        .thinking(ThinkingContent(thinking: "second thought")),
        .text(TextContent(text: "answer")),
    ]))

    let content = try #require(component.children.first as? Container)
    let thinkingRegions = content.children.compactMap { $0 as? MouseRegion }
    #expect(thinkingRegions.count == 1)
    let thinkingRender = try #require(thinkingRegions.first).render(width: 120).joined(separator: "\n")
    #expect(thinkingRender.contains("first thought"))
    #expect(thinkingRender.contains("second thought"))

}

@MainActor
@Test func hiddenConsecutiveThinkingBlocksRenderAsSingleLabel() throws {
    initTheme("dark")
    let component = AssistantMessageComponent(
        message: makeAssistantMessage(content: [
            .thinking(ThinkingContent(thinking: "first thought")),
            .thinking(ThinkingContent(thinking: "second thought")),
            .text(TextContent(text: "answer")),
        ]),
        hideThinkingBlock: true
    )

    let content = try #require(component.children.first as? Container)
    let thinkingLabels = content.children.compactMap { $0 as? MouseRegion }.filter {
        $0.render(width: 120).joined(separator: "\n").contains("Thinking...")
    }

    #expect(thinkingLabels.count == 1)
}
