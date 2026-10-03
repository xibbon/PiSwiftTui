import MiniTui
import PiSwiftCodingAgent

/// Show a sign-in URL with click and copy hints. The host handles the copy key.
public final class AuthUrlComponent: Container {
    public let url: String
    private let requestRender: @MainActor () -> Void
    private let clipboardCopy: @MainActor (String) -> PiSwiftCodingAgent.ClipboardCopyResult
    private let hint: Text

    public init(url: String, requestRender: @escaping @MainActor () -> Void,
                clipboardCopy: @escaping @MainActor (String) -> PiSwiftCodingAgent.ClipboardCopyResult = copyToClipboard) {
        self.url = url
        self.requestRender = requestRender
        self.clipboardCopy = clipboardCopy
        self.hint = Text("", paddingX: 1, paddingY: 0)
        super.init()
        addChild(Text(theme.fg(.accent, hyperlink(url, url: url)), paddingX: 1, paddingY: 0))
        addChild(hint)
        setHint(keyHint(.copyMessage, "to copy"))
    }

    private func setHint(_ suffix: String) {
#if os(macOS)
        let clickHint = "Cmd+click to open"
#else
        let clickHint = "Ctrl+click to open"
#endif
        hint.setText("\(theme.fg(.dim, hyperlink(clickHint, url: url))) \(theme.fg(.dim, "•")) \(suffix)")
        requestRender()
    }

    public func copy() {
        switch clipboardCopy(url) {
        case .success:
            setHint(theme.fg(.success, "Copied URL to clipboard"))
        case .osc52SentUnverified:
            setHint(theme.fg(.warning, "Sent a copy request to the terminal; clipboard not verified"))
        case .failure(let message):
            setHint(theme.fg(.error, message))
        }
    }
}
