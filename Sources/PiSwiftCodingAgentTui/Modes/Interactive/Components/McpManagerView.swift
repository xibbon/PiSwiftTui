import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Render the MCP menu models supplied by PiSwift.
@MainActor
public final class McpManagerView: Component, Focusable, SystemCursorAware, @MainActor HookDisposableComponent, McpUi {
    private let viewTheme: Theme
    private let requestRender: @MainActor @Sendable () -> Void
    private var content = Container()
    private var inputHandler: ((String) -> Void)?
    private var inputTarget: (any Focusable)?
    private var cursorTarget: (any SystemCursorAware)?
    private var cancelPrompt: (() -> Void)?
    var authURLCopy: @MainActor (String) -> PiSwiftCodingAgent.ClipboardCopyResult = copyToClipboard

    public var focused = false {
        didSet { inputTarget?.focused = focused }
    }
    public var usesSystemCursor = false {
        didSet { cursorTarget?.usesSystemCursor = usesSystemCursor }
    }

    public init(theme: Theme, requestRender: @escaping @MainActor @Sendable () -> Void) {
        self.viewTheme = theme
        self.requestRender = requestRender
        content = frame(title: "MCP servers", body: [Text(theme.fg(.muted, "Loading…"), paddingX: 1, paddingY: 1)])
    }

    public func menu(_ menu: McpMenu) async -> String? {
        await self.menu(build: { menu }, changes: nil)
    }

    public func menu(build: @escaping @Sendable () async -> McpMenu,
                     changes: AsyncStream<Void>?) async -> String? {
        let prompt = McpMenuPrompt()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let model = await build()
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                cancelPrompt?()
                prompt.install(continuation)
                cancelPrompt = { prompt.finish(nil) }
                showMenu(model, prompt: prompt)
                if let changes {
                    prompt.consumer = Task { [weak self] in
                        for await _ in changes {
                            guard !Task.isCancelled, !prompt.settled else { break }
                            let model = await build()
                            guard !Task.isCancelled, !prompt.settled else { break }
                            self?.showMenu(model, prompt: prompt)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in prompt.finish(nil) }
        }
    }

    private func showMenu(_ menu: McpMenu, prompt: McpMenuPrompt) {
        let wanted = prompt.selected ?? menu.selected
        var body: [any Component] = []
        if let details = menu.details, !details.isEmpty {
            body.append(Text(viewTheme.fg(.muted, details), paddingX: 1, paddingY: 0))
        }
        if let error = menu.error, !error.isEmpty {
            body.append(Text(viewTheme.fg(.error, error), paddingX: 1, paddingY: 0))
        }
        body.append(Spacer(1))
        if menu.items.isEmpty {
            body.append(Text(viewTheme.fg(.muted, menu.empty ?? "Nothing to show."), paddingX: 1, paddingY: 0))
            setContent(frame(title: menu.title, body: body, footer: hint(.selectCancel, menu.cancelLabel)), inputHandler: { data in
                if getKeybindings().matches(data, TUIKeybinding.selectCancel) { prompt.finish(nil) }
            })
            return
        }
        let list = SelectList(items: menu.items.map {
            SelectItem(value: $0.id, label: $0.label, description: $0.detail)
        }, maxVisible: min(menu.items.count, 12), theme: getSelectListTheme())
        if let index = menu.items.firstIndex(where: { $0.id == wanted }) { list.setSelectedIndex(index) }
        prompt.selected = list.getSelectedItem()?.value
        list.onSelectionChange = { prompt.selected = $0.value }
        list.onSelect = { prompt.finish($0.value) }
        list.onCancel = { prompt.finish(nil) }
        body.append(list)
        let footer = "\(hint(.selectConfirm, menu.confirmLabel)) • \(hint(.selectCancel, menu.cancelLabel))"
        setContent(frame(title: menu.title, body: body, footer: footer), inputHandler: { list.handleInput($0) }, cursorTarget: list)
    }

    public func status(title: String, message: String) {
        setContent(frame(title: title, body: [Spacer(1), Text(viewTheme.fg(.muted, message), paddingX: 1, paddingY: 0)]))
    }

    public func redirectURL(title: String, authorizationURL: URL) async -> URL? {
        let prompt = McpRedirectPrompt()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                cancelPrompt?()
                prompt.install(continuation)
                cancelPrompt = { prompt.finish(nil) }
                let input = Input()
                let link = AuthUrlComponent(url: authorizationURL.absoluteString, requestRender: requestRender,
                                            clipboardCopy: authURLCopy)
                let body: [any Component] = [
                    Spacer(1),
                    Text(viewTheme.fg(.muted, "Approve access in your browser. If it did not open, visit:"), paddingX: 1, paddingY: 0),
                    link,
                    Spacer(1),
                    Text(viewTheme.fg(.muted, "If the browser runs on another machine, paste the URL it was redirected to:"), paddingX: 1, paddingY: 0),
                    input,
                ]
                let footer = "\(hint(.selectConfirm, "submit")) • \(hint(.selectCancel, "cancel"))"
                setContent(frame(title: title, body: body, footer: footer), inputHandler: { data in
                    let keys = getKeybindings()
                    if keys.matches(data, TUIKeybinding.selectConfirm) {
                        let value = input.getValue().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty, let url = URL(string: value) { prompt.finish(url) }
                        return
                    }
                    if keys.matches(data, TUIKeybinding.selectCancel) {
                        prompt.finish(nil)
                        return
                    }
                    if appKeyMatches(data, .copyMessage) {
                        link.copy()
                        return
                    }
                    input.handleInput(data)
                }, inputTarget: input, cursorTarget: input)
            }
        } onCancel: {
            Task { @MainActor in prompt.finish(nil) }
        }
    }

    public func handleInput(_ data: String) {
        inputHandler?(data)
        requestRender()
    }

    public func render(width: Int) -> [String] {
        content.render(width: width).map {
            visibleWidth($0) > width ? truncateToWidth($0, maxWidth: width, ellipsis: "") : $0
        }
    }

    public func invalidate() { content.invalidate() }

    public func dispose() {
        cancelPrompt?()
        cancelPrompt = nil
        inputTarget?.focused = false
        inputHandler = nil
    }

    private func setContent(_ content: Container, inputHandler: ((String) -> Void)? = nil,
                            inputTarget: (any Focusable)? = nil, cursorTarget: (any SystemCursorAware)? = nil) {
        self.inputTarget?.focused = false
        self.content = content
        self.inputHandler = inputHandler
        self.inputTarget = inputTarget
        self.cursorTarget = cursorTarget
        inputTarget?.focused = focused
        cursorTarget?.usesSystemCursor = usesSystemCursor
        requestRender()
    }

    private func frame(title: String, body: [any Component], footer: String? = nil) -> Container {
        let container = Container()
        container.addChild(DynamicBorder(color: { [viewTheme] in viewTheme.fg(.accent, $0) }))
        container.addChild(Text(viewTheme.fg(.accent, viewTheme.bold(title)), paddingX: 1, paddingY: 0))
        for child in body { container.addChild(child) }
        if let footer, !footer.isEmpty {
            container.addChild(Spacer(1))
            container.addChild(Text(viewTheme.fg(.dim, footer), paddingX: 1, paddingY: 0))
        }
        container.addChild(DynamicBorder(color: { [viewTheme] in viewTheme.fg(.accent, $0) }))
        return container
    }

    private func hint(_ action: EditorAction, _ label: String) -> String {
        keyHint(action, label)
    }
}

@MainActor
private final class McpMenuPrompt {
    var selected: String?
    var consumer: Task<Void, Never>?
    private(set) var settled = false
    private var continuation: CheckedContinuation<String?, Never>?

    func install(_ continuation: CheckedContinuation<String?, Never>) {
        if settled { continuation.resume(returning: nil) }
        else { self.continuation = continuation }
    }

    func finish(_ value: String?) {
        guard !settled else { return }
        settled = true
        consumer?.cancel()
        consumer = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class McpRedirectPrompt {
    private var settled = false
    private var continuation: CheckedContinuation<URL?, Never>?

    func install(_ continuation: CheckedContinuation<URL?, Never>) {
        if settled { continuation.resume(returning: nil) }
        else { self.continuation = continuation }
    }

    func finish(_ value: URL?) {
        guard !settled else { return }
        settled = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}
