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

public final class LoginDialogComponent: Container, SystemCursorAware, Focusable {
    private let contentContainer: Container
    private let input: Input
    private let tui: TUI
    private let onComplete: (Bool, String?) -> Void
    private var inputResolver: ((String) -> Void)?
    private var inputRejecter: ((Error) -> Void)?
    private var activeInputContainer: Container?
    private var inputIsSecret = false
    private var pendingInputId: UUID?
    private var removeInputCancellationHandler: (@Sendable () -> Void)?
    var authBrowserOpener: (String) -> Bool = openBrowser
    var authClipboardCopy: (String) -> PiSwiftCodingAgent.ClipboardCopyResult = copyToClipboard
    public let signal: CancellationToken
    public var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }
    public var usesSystemCursor: Bool {
        get { input.usesSystemCursor }
        set { input.usesSystemCursor = newValue }
    }

    public init(
        tui: TUI,
        providerId: String,
        providerName: String? = nil,
        title: String? = nil,
        onComplete: @escaping (Bool, String?) -> Void
    ) {
        self.tui = tui
        self.onComplete = onComplete
        self.contentContainer = Container()
        self.input = Input()
        self.signal = CancellationToken()

        super.init()

        let name = providerName ?? providerId

        addChild(DynamicBorder())
        addChild(Text(theme.fg(.accent, theme.bold(title ?? "Login to \(name)")), paddingX: 1, paddingY: 0))
        addChild(contentContainer)
        addChild(DynamicBorder())
        input.onSubmit = { [weak self] _ in self?.submitInput() }
        input.onEscape = { [weak self] in self?.cancel() }
    }

    private func rejectPendingInput() {
        let rejecter = inputRejecter
        activeInputContainer?.clear()
        activeInputContainer = nil
        inputResolver = nil
        inputRejecter = nil
        pendingInputId = nil
        removeInputCancellationHandler?()
        removeInputCancellationHandler = nil
        rejecter?(LoginDialogError.cancelled)
    }

    private func submitInput() {
        guard !signal.isCancelled else { rejectPendingInput(); return }
        guard let resolver = inputResolver else { return }
        let value = input.getValue()
        // Q3: upstream echoes secrets. Keep a bounded mask in submitted history.
        let submitted = inputIsSecret ? String(repeating: "•", count: min(value.count, 8)) : value
        activeInputContainer?.clear()
        activeInputContainer?.addChild(Text("> \(submitted)", paddingX: 0, paddingY: 0))
        activeInputContainer = nil
        inputResolver = nil
        inputRejecter = nil
        pendingInputId = nil
        removeInputCancellationHandler?()
        removeInputCancellationHandler = nil
        resolver(value)
        tui.requestRender()
    }

    private func awaitInput(secret: Bool = false) async throws -> String {
        guard !signal.isCancelled else { throw LoginDialogError.cancelled }
        guard !Task.isCancelled else { throw LoginDialogError.cancelled }
        inputIsSecret = secret
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingInputId = id
                inputResolver = { value in continuation.resume(returning: value) }
                inputRejecter = { error in continuation.resume(throwing: error) }
                removeInputCancellationHandler = signal.onCancel { [weak self] in
                    Task { @MainActor in self?.rejectPendingInput() }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.pendingInputId == id else { return }
                self?.rejectPendingInput()
            }
        }
    }

    private func addInput() {
        let container = Container()
        container.addChild(input)
        activeInputContainer = container
        contentContainer.addChild(container)
    }

    private func cancel() {
        signal.cancel()
        rejectPendingInput()
        onComplete(false, "Login cancelled")
    }

    public func showAuth(_ url: String, _ instructions: String?) {
        contentContainer.clear()
        contentContainer.addChild(Spacer(1))
        let linkedUrl = "\u{001B}]8;;\(url)\u{0007}\(url)\u{001B}]8;;\u{0007}"
        contentContainer.addChild(Text(theme.fg(.accent, linkedUrl), paddingX: 1, paddingY: 0))

#if os(macOS)
        let clickHint = "Cmd+click to open"
#else
        let clickHint = "Ctrl+click to open"
#endif
        let hyperlink = "\u{001B}]8;;\(url)\u{0007}\(clickHint)\u{001B}]8;;\u{0007}"
        contentContainer.addChild(Text(theme.fg(.dim, hyperlink), paddingX: 1, paddingY: 0))

        let copyNotice = loginClipboardNotice(for: authClipboardCopy(url))
        contentContainer.addChild(Text(theme.fg(.dim, copyNotice), paddingX: 1, paddingY: 0))

        if let instructions {
            contentContainer.addChild(Spacer(1))
            contentContainer.addChild(Text(theme.fg(.warning, instructions), paddingX: 1, paddingY: 0))
        }

        if !authBrowserOpener(url) {
            contentContainer.addChild(Spacer(1))
            contentContainer.addChild(Text(theme.fg(.warning, "Failed to open browser. Copy the URL above into your browser."), paddingX: 1, paddingY: 0))
        }
        tui.requestRender()
    }

    public func showManualInput(_ prompt: String) async throws -> String {
        guard !signal.isCancelled, !Task.isCancelled else { throw LoginDialogError.cancelled }
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(Text(theme.fg(.dim, prompt), paddingX: 1, paddingY: 0))
        addInput()
        contentContainer.addChild(Text(theme.fg(.dim, "(Escape to cancel)"), paddingX: 1, paddingY: 0))

        input.setValue("")
        tui.requestRender()

        return try await awaitInput()
    }

    public func showPrompt(_ message: String, _ placeholder: String? = nil, secret: Bool = false) async throws -> String {
        guard !signal.isCancelled else { throw LoginDialogError.cancelled }
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(Text(theme.fg(.text, message), paddingX: 1, paddingY: 0))
        if let placeholder {
            contentContainer.addChild(Text(theme.fg(.dim, "e.g., \(placeholder)"), paddingX: 1, paddingY: 0))
        }
        addInput()
        contentContainer.addChild(Text(theme.fg(.dim, "(Escape to cancel, Enter to submit)"), paddingX: 1, paddingY: 0))
        // MiniTui Input has no secret display option. Q3 permits masking after Enter.
        input.setValue("")
        tui.requestRender()
        return try await awaitInput(secret: secret)
    }

    public func showDetails(_ lines: [String]) {
        contentContainer.clear()
        contentContainer.addChild(Spacer(1))
        for line in lines {
            contentContainer.addChild(Text(line, paddingX: 1, paddingY: 0))
        }
        tui.requestRender()
    }

    public func showInfo(_ message: String, links: [AuthInfoLink] = [], showCloseHint: Bool = false) {
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(Text(theme.fg(.text, message), paddingX: 1, paddingY: 0))
        for link in links {
            let text = link.label.flatMap { $0.isEmpty ? nil : "\($0): \(link.url)" } ?? link.url
            let hyperlink = "\u{001B}]8;;\(link.url)\u{0007}\(text)\u{001B}]8;;\u{0007}"
            contentContainer.addChild(Text(theme.fg(.accent, hyperlink), paddingX: 1, paddingY: 0))
        }
        if showCloseHint {
            contentContainer.addChild(Spacer(1))
            contentContainer.addChild(Text("(Escape to close)", paddingX: 1, paddingY: 0))
        }
        tui.requestRender()
    }

    public func showWaiting(_ message: String) {
        contentContainer.addChild(Spacer(1))
        contentContainer.addChild(Text(theme.fg(.dim, message), paddingX: 1, paddingY: 0))
        contentContainer.addChild(Text(theme.fg(.dim, "(Escape to cancel)"), paddingX: 1, paddingY: 0))
        tui.requestRender()
    }

    public func showProgress(_ message: String) {
        contentContainer.addChild(Text(theme.fg(.dim, message), paddingX: 1, paddingY: 0))
        tui.requestRender()
    }

    public override func handleInput(_ keyData: String) {
        if isEscape(keyData) || isCtrlC(keyData) {
            cancel()
            return
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
