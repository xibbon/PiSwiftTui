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
    private var hiddenThinkingLabel: String?
    private var lastMessage: AssistantMessage?
    private var thinkingVisibilityOverrides: [Int: Bool] = [:]
    private var hasToolCalls: Bool = false
    private var markdownConfiguration: InteractiveTuiConfiguration
    private var isStreaming: Bool
    private let markdownRunner: HookRunner?
    private let messageId: String?
    private let messageTimestamp: String?
    private let markdownStreamingState: LockedState<Bool>
    private struct MarkdownSlot {
        enum Kind { case text, thinking }
        let kind: Kind
        let markdown: Markdown
    }
    private var markdownSlots: [MarkdownSlot] = []

    public init(
        message: AssistantMessage? = nil,
        hideThinkingBlock: Bool = false,
        hiddenThinkingLabel: String? = nil,
        markdownConfiguration: InteractiveTuiConfiguration = InteractiveTuiConfiguration(),
        isStreaming: Bool = false,
        markdownRunner: HookRunner? = nil,
        messageId: String? = nil,
        messageTimestamp: String? = nil
    ) {
        self.contentContainer = Container()
        self.hideThinkingBlock = hideThinkingBlock
        self.hiddenThinkingLabel = hiddenThinkingLabel
        self.markdownConfiguration = markdownConfiguration
        self.isStreaming = isStreaming
        self.markdownRunner = markdownRunner
        self.messageId = messageId
        self.messageTimestamp = messageTimestamp
        self.markdownStreamingState = LockedState(isStreaming)
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

    public func setHiddenThinkingLabel(_ label: String?) {
        hiddenThinkingLabel = label
        if let lastMessage { updateContent(lastMessage) }
    }

    public func setStreaming(_ streaming: Bool) {
        guard isStreaming != streaming else { return }
        isStreaming = streaming
        markdownStreamingState.withLock { $0 = streaming }
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    public func setMarkdownConfiguration(_ configuration: InteractiveTuiConfiguration) {
        markdownConfiguration = configuration
        markdownSlots.removeAll()
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    private func markdownOptions(type: MarkdownMessageType, includeMermaid: Bool) -> MarkdownOptions {
        var transforms: [MarkdownSourceTransform] = []
        if let transform = hostMarkdownTransform(runner: markdownRunner, type: type,
            streamingState: markdownStreamingState, messageId: messageId, timestamp: messageTimestamp) {
            transforms.append(transform)
        }
        if includeMermaid && markdownConfiguration.mermaidEnabled {
            let state = markdownStreamingState
            let renderWhileStreaming = markdownConfiguration.mermaidRenderWhileStreaming
            let streamingTransform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(
                enabled: true, renderWhileStreaming: renderWhileStreaming,
                isStreaming: true, theme: theme))
            let finalTransform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(
                enabled: true, renderWhileStreaming: renderWhileStreaming,
                isStreaming: false, theme: theme))
            transforms.append { source, width in
                return state.withLock { $0 } ? streamingTransform(source, width) : finalTransform(source, width)
            }
        }
        return MarkdownOptions(
            renderLatex: markdownConfiguration.latexEnabled,
            sourceTransforms: transforms
        )
    }

    public func updateContent(_ message: AssistantMessage) {
        lastMessage = message
        contentContainer.clear()
        let previousSlots = markdownSlots
        markdownSlots = []
        func markdownBlock(_ kind: MarkdownSlot.Kind, text: String, create: () -> Markdown) -> Markdown {
            let slot = markdownSlots.count < previousSlots.count ? previousSlots[markdownSlots.count] : nil
            let markdown = slot?.kind == kind ? slot!.markdown : create()
            markdown.setText(text)
            markdownSlots.append(MarkdownSlot(kind: kind, markdown: markdown))
            return markdown
        }

        let hasContent = message.content.contains { block in
            switch block {
            case .text(let text):
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(let thinking):
                return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (!hideThinkingBlock || !(hiddenThinkingLabel ?? "Thinking...").isEmpty ||
                     thinkingVisibilityOverrides.values.contains(false))
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
                    contentContainer.addChild(markdownBlock(.text, text: trimmed) { Markdown(
                        trimmed,
                        paddingX: markdownConfiguration.outputPad,
                        paddingY: 0,
                        theme: getMarkdownTheme(),
                        options: markdownOptions(type: .assistant, includeMermaid: true)
                    ) })
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
                        return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            (!hideThinkingBlock || !(hiddenThinkingLabel ?? "Thinking...").isEmpty)
                    default:
                        return false
                    }
                }

                let runIndex = thinkingRunIndex
                thinkingRunIndex += 1
                let hidden = thinkingVisibilityOverrides[runIndex] ?? hideThinkingBlock
                if hidden && (hiddenThinkingLabel ?? "Thinking...").isEmpty { continue }
                let thinkingComponent: Component
                if hidden {
                    thinkingComponent = Text(
                        theme.italic(theme.fg(.thinkingText, hiddenThinkingLabel ?? "Thinking...")),
                        paddingX: markdownConfiguration.outputPad, paddingY: 0)
                } else {
                    let thinkingText = thinkingBlocks.joined(separator: "\n\n")
                    thinkingComponent = markdownBlock(.thinking, text: thinkingText) { Markdown(
                        thinkingText,
                        paddingX: markdownConfiguration.outputPad, paddingY: 0,
                        theme: getMarkdownTheme(),
                        defaultTextStyle: DefaultTextStyle(color: { theme.fg(.thinkingText, $0) }, italic: true),
                        options: markdownOptions(type: .assistantThinking, includeMermaid: false)) }
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
