import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class BranchSummaryMessageComponent: Box {
    private var expanded = false
    private let message: BranchSummaryMessage

    public init(message: BranchSummaryMessage) {
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
        let label = theme.fg(.customMessageLabel, "\u{001B}[1m[branch]\u{001B}[22m")
        content.addChild(Text(label, paddingX: 0, paddingY: 0))
        content.addChild(Spacer(1))

        if expanded {
            let header = "**Branch Summary**\n\n"
            let style = DefaultTextStyle(color: { theme.fg(.customMessageText, $0) })
            content.addChild(Markdown(header + message.summary, paddingX: 0, paddingY: 0, theme: getMarkdownTheme(), defaultTextStyle: style))
        } else {
            content.addChild(Text(theme.fg(.customMessageText, "Branch summary (ctrl+o to expand)"), paddingX: 0, paddingY: 0))
        }
        addChild(MouseRegion(child: content) { [weak self] event in
            guard let self, event.type == .click, event.button == .left else { return nil }
            self.setExpanded(!self.expanded)
            return TuiMouseEventResult(handled: true)
        })
    }
}
