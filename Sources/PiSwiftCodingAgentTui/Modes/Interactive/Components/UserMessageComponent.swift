import Foundation
import MiniTui
import PiSwiftCodingAgent

private let OSC133_ZONE_START = "\u{001B}]133;A\u{0007}"
private let OSC133_ZONE_END = "\u{001B}]133;B\u{0007}"
private let OSC133_ZONE_FINAL = "\u{001B}]133;C\u{0007}"

public final class UserMessageComponent: Container {
    public init(
        text: String,
        markdownConfiguration: InteractiveTuiConfiguration = InteractiveTuiConfiguration(),
        markdownRunner: HookRunner? = nil,
        messageId: String? = nil,
        messageTimestamp: String? = nil
    ) {
        super.init()
        addChild(Spacer(1))
        let style = DefaultTextStyle(
            color: { theme.fg(.userMessageText, $0) },
            bgColor: { theme.bg(.userMessageBg, $0) }
        )
        let transforms = hostMarkdownTransform(runner: markdownRunner, type: .user,
            messageId: messageId, timestamp: messageTimestamp).map { [$0] } ?? []
        addChild(Markdown(
            text,
            paddingX: markdownConfiguration.outputPad,
            paddingY: 1,
            theme: getMarkdownTheme(),
            defaultTextStyle: style,
            options: MarkdownOptions(renderLatex: markdownConfiguration.latexEnabled, sourceTransforms: transforms)
        ))
    }

    public override func render(width: Int) -> [String] {
        var lines = super.render(width: width)
        if lines.isEmpty { return lines }
        lines[0] = OSC133_ZONE_START + lines[0]
        lines[lines.count - 1] = OSC133_ZONE_END + OSC133_ZONE_FINAL + lines[lines.count - 1]
        return lines
    }
}
