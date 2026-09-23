import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class CompactionSummaryMessageComponent: Box {
    private var expanded = false
    private let message: CompactionSummaryMessage

    public init(message: CompactionSummaryMessage) {
        self.message = message
        super.init(paddingX: 1, paddingY: 1, bgFn: { theme.bg(.customMessageBg, $0) })
        updateDisplay()
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
            content.addChild(Markdown(header + message.summary, paddingX: 0, paddingY: 0, theme: getMarkdownTheme(), defaultTextStyle: style))
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
