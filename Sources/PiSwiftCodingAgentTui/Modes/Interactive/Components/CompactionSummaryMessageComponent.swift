import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class CompactionSummaryMessageComponent: Box, OutputPaddingSetting {
    private var expanded = false
    private let message: CompactionSummaryMessage
    private let markdownRunner: HookRunner?
    private let messageId: String?
    private let messageTimestamp: String?
    private let mermaidEnabled: Bool

    public init(message: CompactionSummaryMessage, outputPad: Int = 1,
                markdownRunner: HookRunner? = nil, messageId: String? = nil,
                messageTimestamp: String? = nil, mermaidEnabled: Bool = true) {
        self.message = message
        self.markdownRunner = markdownRunner
        self.messageId = messageId
        self.messageTimestamp = messageTimestamp
        self.mermaidEnabled = mermaidEnabled
        super.init(paddingX: outputPad, paddingY: 1, bgFn: { theme.bg(.customMessageBg, $0) })
        updateDisplay()
    }

    public func setOutputPad(_ outputPad: Int) {
        setPaddingX(outputPad)
    }

    public func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        updateDisplay()
    }

    public override func invalidate() {
        super.invalidate()
        updateDisplay()
    }

    private func updateDisplay() {
        clear()
        let content = Container()
        let tokenStr = NumberFormatter.localizedString(from: NSNumber(value: message.tokensBefore), number: .decimal)
        let label = theme.fg(.customMessageLabel, "\u{001B}[1m[compaction]\u{001B}[22m")
        content.addChild(Text(label, paddingX: 0, paddingY: 0))
        content.addChild(Spacer(1))

        if expanded {
            let header = "**Compacted from \(tokenStr) tokens**\n\n"
            let style = DefaultTextStyle(color: { theme.fg(.customMessageText, $0) })
            var transforms = hostPrefixedMarkdownTransform(runner: markdownRunner, type: .summary, header: header,
                messageId: messageId, timestamp: messageTimestamp).map { [$0] } ?? []
            if mermaidEnabled {
                transforms.append(createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(theme: theme)))
            }
            content.addChild(Markdown(header + message.summary, paddingX: 0, paddingY: 0,
                theme: getMarkdownTheme(), defaultTextStyle: style,
                options: MarkdownOptions(sourceTransforms: transforms)))
        } else {
            content.addChild(Text(theme.fg(.customMessageText, "Compacted from \(tokenStr) tokens (ctrl+o to expand)"), paddingX: 0, paddingY: 0))
        }
        addChild(MouseRegion(child: content) { [weak self] event in
            guard let self, event.type == .click, event.button == .left else { return nil }
            self.setExpanded(!self.expanded)
            return TuiMouseEventResult(handled: true)
        })
    }
}
