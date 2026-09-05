import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

private let OSC133_ZONE_START = "\u{001B}]133;A\u{0007}"
private let OSC133_ZONE_END = "\u{001B}]133;B\u{0007}"
private let OSC133_ZONE_FINAL = "\u{001B}]133;C\u{0007}"

public final class AssistantMessageComponent: Container {
    private let contentContainer: Container
    private var hideThinkingBlock: Bool
    private var lastMessage: AssistantMessage?
    private var thinkingVisibilityOverrides: [Int: Bool] = [:]
    private var hasToolCalls: Bool = false
    private var markdownConfiguration: InteractiveTuiConfiguration
    private var isStreaming: Bool

    public init(
        message: AssistantMessage? = nil,
        hideThinkingBlock: Bool = false,
        markdownConfiguration: InteractiveTuiConfiguration = InteractiveTuiConfiguration(),
        isStreaming: Bool = false
    ) {
        self.contentContainer = Container()
        self.hideThinkingBlock = hideThinkingBlock
        self.markdownConfiguration = markdownConfiguration
        self.isStreaming = isStreaming
        super.init()
        addChild(contentContainer)
        if let message {
            updateContent(message)
        }
    }

    public override func invalidate() {
        super.invalidate()
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    public override func render(width: Int) -> [String] {
        var lines = super.render(width: width)
        if hasToolCalls || lines.isEmpty {
            return lines
        }
        lines[0] = OSC133_ZONE_START + lines[0]
        lines[lines.count - 1] = OSC133_ZONE_END + OSC133_ZONE_FINAL + lines[lines.count - 1]
        return lines
    }

    public func setHideThinkingBlock(_ hide: Bool) {
        hideThinkingBlock = hide
        thinkingVisibilityOverrides.removeAll()
        if let lastMessage { updateContent(lastMessage) }
    }

    public func setStreaming(_ streaming: Bool) {
        guard isStreaming != streaming else { return }
        isStreaming = streaming
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    public func setMarkdownConfiguration(_ configuration: InteractiveTuiConfiguration) {
        markdownConfiguration = configuration
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    private func markdownOptions(includeMermaid: Bool) -> MarkdownOptions {
        var transforms: [MarkdownSourceTransform] = []
        if includeMermaid && markdownConfiguration.mermaidEnabled {
            transforms.append(createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(
                enabled: true,
                renderWhileStreaming: markdownConfiguration.mermaidRenderWhileStreaming,
                isStreaming: isStreaming,
                theme: theme
            )))
        }
        return MarkdownOptions(
            renderLatex: markdownConfiguration.latexEnabled,
            sourceTransforms: transforms
        )
    }

    public func updateContent(_ message: AssistantMessage) {
        lastMessage = message
        contentContainer.clear()

        let hasContent = message.content.contains { block in
            switch block {
            case .text(let text):
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(let thinking):
                return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }

        if hasContent {
            contentContainer.addChild(Spacer(1))
        }

        var thinkingRunIndex = 0
        var index = 0
        while index < message.content.count {
            let block = message.content[index]
            switch block {
            case .text(let textContent):
                let trimmed = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    contentContainer.addChild(Markdown(
                        trimmed,
                        paddingX: markdownConfiguration.outputPad,
                        paddingY: 0,
                        theme: getMarkdownTheme(),
                        options: markdownOptions(includeMermaid: true)
                    ))
                }
                index += 1
            case .thinking:
                var thinkingBlocks: [String] = []
                while index < message.content.count {
                    guard case .thinking(let thinkingContent) = message.content[index] else { break }
                    let trimmed = thinkingContent.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        thinkingBlocks.append(trimmed)
                    }
                    index += 1
                }

                if thinkingBlocks.isEmpty { continue }

                let hasVisibleContentAfter = message.content.suffix(from: index).contains { block in
                    switch block {
                    case .text(let text):
                        return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .thinking(let thinking):
                        return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    default:
                        return false
                    }
                }

                let runIndex = thinkingRunIndex
                thinkingRunIndex += 1
                let hidden = thinkingVisibilityOverrides[runIndex] ?? hideThinkingBlock
                let thinkingComponent: Component
                if hidden {
                    thinkingComponent = Text(
                        theme.italic(theme.fg(.thinkingText, "Thinking...")),
                        paddingX: markdownConfiguration.outputPad, paddingY: 0)
                } else {
                    thinkingComponent = Markdown(
                        thinkingBlocks.joined(separator: "\n\n"),
                        paddingX: markdownConfiguration.outputPad, paddingY: 0,
                        theme: getMarkdownTheme(),
                        defaultTextStyle: DefaultTextStyle(color: { theme.fg(.thinkingText, $0) }, italic: true),
                        options: markdownOptions(includeMermaid: false))
                }
                contentContainer.addChild(MouseRegion(child: thinkingComponent) { [weak self] event in
                    guard let self, event.type == .click, event.button == .left else { return nil }
                    self.thinkingVisibilityOverrides[runIndex] = !hidden
                    if let lastMessage = self.lastMessage { self.updateContent(lastMessage) }
                    return TuiMouseEventResult(handled: true)
                })
                if hasVisibleContentAfter {
                    contentContainer.addChild(Spacer(1))
                }
            default:
                index += 1
            }
        }

        let hasToolCalls = message.content.contains { block in
            if case .toolCall = block {
                return true
            }
            return false
        }
        self.hasToolCalls = hasToolCalls

        if !hasToolCalls {
            switch message.stopReason {
            case .aborted:
                contentContainer.addChild(Text(
                    theme.fg(.error, "\nAborted"),
                    paddingX: markdownConfiguration.outputPad,
                    paddingY: 0
                ))
            case .error:
                let errorMsg = message.errorMessage ?? "Unknown error"
                contentContainer.addChild(Spacer(1))
                contentContainer.addChild(Text(
                    theme.fg(.error, "Error: \(errorMsg)"),
                    paddingX: markdownConfiguration.outputPad,
                    paddingY: 0
                ))
            default:
                break
            }
        }
    }
}
