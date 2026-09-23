import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public enum LoginDialogError: Error, LocalizedError {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Login cancelled"
        }
    }
}

func loginClipboardNotice(for result: PiSwiftCodingAgent.ClipboardCopyResult) -> String {
    switch result {
    case .success:
        return "URL copied to clipboard"
    case .osc52SentUnverified:
        return "Sent a copy request to the terminal; copy the URL above if needed"
    case .failure:
        return "Copy the URL above into your browser"
    }
}

public final class LoginDialogComponent: Container, SystemCursorAware {
    private let contentContainer: Container
    private let input: Input
    private let tui: TUI
    private let onComplete: (Bool, String?) -> Void
    private var inputResolver: ((String) -> Void)?
    private var inputRejecter: ((Error) -> Void)?
    public let signal: CancellationToken
    public var usesSystemCursor: Bool {
        get { input.usesSystemCursor }
        set { input.usesSystemCursor = newValue }
    }

    public init(
        tui: TUI,
        providerId: String,
        onComplete: @escaping (Bool, String?) -> Void
    ) {
        self.tui = tui
        self.onComplete = onComplete
        self.contentContainer = Container()
        self.input = Input()
        self.signal = CancellationToken()

        super.init()

        let providerInfo = getOAuthProviders().first { $0.id.rawValue == providerId }
        let providerName = providerInfo?.name ?? providerId

        addChild(DynamicBorder())
        addChild(Text(theme.fg(.warning, "Login to \(providerName)"), paddingX: 1, paddingY: 0))
        addChild(contentContainer)
        addChild(DynamicBorder())
    }

    private func cancel() {
        signal.cancel()
        if let inputRejecter {
            inputRejecter(LoginDialogError.cancelled)
            self.inputResolver = nil
            self.inputRejecter = nil
        }
        onComplete(false, "Login cancelled")
    }

    public func showAuth(_ url: String, _ instructions: String?) {
        contentContainer.clear()
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(TruncatedText(theme.fg(.accent, url), paddingX: 1, paddingY: 0))

        let hyperlink = "\u{001B}]8;;\(url)\u{0007}Click here to Login\u{001B}]8;;\u{0007}"
        contentContainer.addChild(TruncatedText(theme.fg(.dim, hyperlink), paddingX: 1, paddingY: 0))

        let copyNotice = loginClipboardNotice(for: copyToClipboard(url))
        contentContainer.addChild(TruncatedText(theme.fg(.dim, copyNotice), paddingX: 1, paddingY: 0))

        if let instructions {
            contentContainer.addChild(Spacer(1))
            contentContainer.addChild(TruncatedText(theme.fg(.warning, instructions), paddingX: 1, paddingY: 0))
        }

        if !openBrowser(url) {
            contentContainer.addChild(Spacer(1))
            contentContainer.addChild(TruncatedText(theme.fg(.warning, "Failed to open browser. Copy the URL above into your browser."), paddingX: 1, paddingY: 0))
        }
        tui.requestRender()
    }

    public func showManualInput(_ prompt: String) async throws -> String {
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(TruncatedText(theme.fg(.dim, prompt), paddingX: 1, paddingY: 0))
        contentContainer.addChild(input)
        contentContainer.addChild(TruncatedText(theme.fg(.dim, "(Escape to cancel)"), paddingX: 1, paddingY: 0))

        input.setValue("")
        tui.requestRender()

        return try await withCheckedThrowingContinuation { continuation in
            inputResolver = { value in continuation.resume(returning: value) }
            inputRejecter = { error in continuation.resume(throwing: error) }
        }
    }

    public func showPrompt(_ message: String, _ placeholder: String?) async throws -> String {
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(TruncatedText(theme.fg(.text, message), paddingX: 1, paddingY: 0))
        if let placeholder {
            contentContainer.addChild(TruncatedText(theme.fg(.dim, "e.g., \(placeholder)"), paddingX: 1, paddingY: 0))
        }
        contentContainer.addChild(input)
        contentContainer.addChild(TruncatedText(theme.fg(.dim, "(Escape to cancel, Enter to submit)"), paddingX: 1, paddingY: 0))

        input.setValue("")
        tui.requestRender()

        return try await withCheckedThrowingContinuation { continuation in
            inputResolver = { value in continuation.resume(returning: value) }
            inputRejecter = { error in continuation.resume(throwing: error) }
        }
    }

    public func showWaiting(_ message: String) {
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(TruncatedText(theme.fg(.dim, message), paddingX: 1, paddingY: 0))
        contentContainer.addChild(TruncatedText(theme.fg(.dim, "(Escape to cancel)"), paddingX: 1, paddingY: 0))
        tui.requestRender()
    }

    public func showProgress(_ message: String) {
        contentContainer.addChild(TruncatedText(theme.fg(.dim, message), paddingX: 1, paddingY: 0))
        tui.requestRender()
    }

    public override func handleInput(_ keyData: String) {
        if isEscape(keyData) || isCtrlC(keyData) {
            cancel()
            return
        }
        if isEnter(keyData) || keyData == "\n" {
            if let inputResolver {
                inputResolver(input.getValue())
                self.inputResolver = nil
                self.inputRejecter = nil
                return
            }
        }

        input.handleInput(keyData)
    }
}

private func openBrowser(_ url: String) -> Bool {
    let process = Process()
#if os(macOS)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
#elseif os(Windows)
    process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
    process.arguments = ["/c", "start", "", url]
#else
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
    process.arguments = [url]
#endif

    do {
        try process.run()
        return true
    } catch {
        return false
    }
}
