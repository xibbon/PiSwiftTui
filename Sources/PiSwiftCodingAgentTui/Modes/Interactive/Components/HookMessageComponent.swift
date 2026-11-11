import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public final class HookMessageComponent: Container, OutputPaddingSetting {
    private let message: HookMessage
    private let customRenderer: HookMessageRenderer?
    private let box: Box
    private var customComponent: Component?
    private var expanded = false
    private var outputPad: Int
    private let markdownRunner: HookRunner?
    private let messageId: String?
    private let messageTimestamp: String?

    public init(message: HookMessage, customRenderer: HookMessageRenderer? = nil, outputPad: Int = 1,
                markdownRunner: HookRunner? = nil, messageId: String? = nil,
                messageTimestamp: String? = nil) {
        self.message = message
        self.customRenderer = customRenderer
        self.box = Box(paddingX: outputPad, paddingY: 1, bgFn: { theme.bg(.customMessageBg, $0) })
        self.outputPad = outputPad
        self.markdownRunner = markdownRunner
        self.messageId = messageId
        self.messageTimestamp = messageTimestamp
        super.init()

        addChild(Spacer(1))
        rebuild()
    }

    public func setOutputPad(_ outputPad: Int) {
        self.outputPad = outputPad
        rebuild()
    }

    public func setExpanded(_ expanded: Bool) {
        if self.expanded != expanded {
            self.expanded = expanded
            rebuild()
        }
    }

    public override func invalidate() {
        super.invalidate()
        rebuild()
    }

    private func rebuild() {
        if let customComponent {
            removeChild(customComponent)
            self.customComponent = nil
        }
        removeChild(box)

        if let customRenderer {
            let rendered = customRenderer(message, HookMessageRenderOptions(expanded: expanded, outputPad: outputPad, keybindingHints: hostKeybindingHints()), theme)
            if let component = rendered as? Component {
                customComponent = component
                addChild(component)
                return
            }
        }

        addChild(box)
        box.setPaddingX(outputPad)
        box.clear()

        let label = theme.fg(.customMessageLabel, "\u{001B}[1m[\(message.customType)]\u{001B}[22m")
        box.addChild(Text(label, paddingX: 0, paddingY: 0))
        box.addChild(Spacer(1))

        let text: String
        switch message.content {
        case .text(let value):
            text = value
        case .blocks(let blocks):
            text = blocks.compactMap { block in
                if case let .text(text) = block {
                    return text.text
                }
                return nil
            }.joined(separator: "\n")
        }

        let style = DefaultTextStyle(color: { theme.fg(.customMessageText, $0) })
        let transforms = hostMarkdownTransform(runner: markdownRunner, type: .custom,
            messageId: messageId, timestamp: messageTimestamp).map { [$0] } ?? []
        box.addChild(Markdown(text, paddingX: 0, paddingY: 0, theme: getMarkdownTheme(),
            defaultTextStyle: style, options: MarkdownOptions(sourceTransforms: transforms)))
    }
}
