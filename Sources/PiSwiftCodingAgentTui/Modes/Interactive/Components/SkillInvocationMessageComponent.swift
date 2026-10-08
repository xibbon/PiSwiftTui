import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Component that renders a skill invocation message with collapsed/expanded state.
/// Uses same background color as custom messages for visual consistency.
/// Only renders the skill block itself - user message is rendered separately.
public final class SkillInvocationMessageComponent: Container, OutputPaddingSetting {
    private let skillBlock: ParsedSkillBlock
    private let box: Box
    private var expanded = false
    private var expandHint: String

    public init(skillBlock: ParsedSkillBlock, expandHint: String = "ctrl+o", outputPad: Int = 1) {
        self.skillBlock = skillBlock
        self.expandHint = expandHint
        self.box = Box(paddingX: outputPad, paddingY: 1, bgFn: { theme.bg(.customMessageBg, $0) })
        super.init()

        addChild(Spacer(1))
        addChild(box)
        updateDisplay()
    }

    public func setOutputPad(_ outputPad: Int) {
        box.setPaddingX(outputPad)
    }

    public func setExpanded(_ expanded: Bool) {
        if self.expanded != expanded {
            self.expanded = expanded
            updateDisplay()
        }
    }

    public func setExpandHint(_ hint: String) {
        if self.expandHint != hint {
            self.expandHint = hint
            updateDisplay()
        }
    }

    public override func invalidate() {
        super.invalidate()
        updateDisplay()
    }

    private func updateDisplay() {
        box.clear()
        let content = Container()

        if expanded {
            // Expanded: label + skill name header + full content
            let label = theme.fg(.customMessageLabel, "\u{001B}[1m[skill]\u{001B}[22m")
            content.addChild(Text(label, paddingX: 0, paddingY: 0))
            content.addChild(Spacer(1))

            let header = "**\(skillBlock.name)**\n\n"
            let style = DefaultTextStyle(color: { theme.fg(.customMessageText, $0) })
            content.addChild(Markdown(header + skillBlock.content, paddingX: 0, paddingY: 0, theme: getMarkdownTheme(), defaultTextStyle: style))
        } else {
            // Collapsed: single line - [skill] name (hint to expand)
            let line =
                theme.fg(.customMessageLabel, "\u{001B}[1m[skill]\u{001B}[22m ") +
                theme.fg(.customMessageText, skillBlock.name) +
                theme.fg(.dim, " (\(expandHint) to expand)")
            content.addChild(Text(line, paddingX: 0, paddingY: 0))
        }
        box.addChild(MouseRegion(child: content) { [weak self] event in
            guard let self, event.type == .click, event.button == .left else { return nil }
            self.setExpanded(!self.expanded)
            return TuiMouseEventResult(handled: true)
        })
    }
}
