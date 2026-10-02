import Foundation
import MiniTui
import PiSwiftCodingAgent

public enum InteractiveTuiMode: String, CaseIterable, Sendable {
    case regular
    case fullscreen
}

public enum FullscreenScrollbarMode: String, CaseIterable, Sendable {
    case auto
    case always
    case hidden

    var miniTuiValue: ScrollViewScrollbar {
        switch self {
        case .auto: .auto
        case .always: .always
        case .hidden: .hidden
        }
    }
}

public func fullscreenScrollbarStyle(_ text: String) -> String {
    theme.fg(.scrollbarThumb, text)
}

public struct InteractiveTuiConfiguration: Sendable, Equatable {
    public var mode: InteractiveTuiMode
    public var scrollbar: FullscreenScrollbarMode
    public var mouseWheelStep: Int
    public var fullscreenWheelScrollLines: PiSwiftCodingAgent.WheelScrollLines
    public var mermaidEnabled: Bool
    public var mermaidRenderWhileStreaming: Bool
    public var latexEnabled: Bool
    public var outputPad: Int

    public init(
        mode: InteractiveTuiMode = .regular,
        scrollbar: FullscreenScrollbarMode = .auto,
        mouseWheelStep: Int? = nil,
        mermaidEnabled: Bool = true,
        mermaidRenderWhileStreaming: Bool = true,
        latexEnabled: Bool = false,
        outputPad: Int = 1,
        fullscreenWheelScrollLines: PiSwiftCodingAgent.WheelScrollLines? = nil
    ) {
        self.mode = mode
        self.scrollbar = scrollbar
        self.mouseWheelStep = max(1, mouseWheelStep ?? 1)
        self.fullscreenWheelScrollLines = fullscreenWheelScrollLines ?? mouseWheelStep.map { .lines(max(1, min(100, $0))) } ?? .auto
        self.mermaidEnabled = mermaidEnabled
        self.mermaidRenderWhileStreaming = mermaidRenderWhileStreaming
        self.latexEnabled = latexEnabled
        self.outputPad = outputPad == 0 ? 0 : 1
    }

    public init(settingsManager: SettingsManager, modeOverride: InteractiveTuiMode? = nil) {
        self.init(
            mode: modeOverride ?? InteractiveTuiMode(rawValue: settingsManager.getTuiMode()) ?? .fullscreen,
            scrollbar: FullscreenScrollbarMode(rawValue: settingsManager.getFullscreenScrollbar()) ?? .auto,
            mouseWheelStep: settingsManager.getMouseWheelStep(),
            mermaidEnabled: settingsManager.getMermaidEnabled(),
            mermaidRenderWhileStreaming: settingsManager.getMermaidRenderWhileStreaming(),
            latexEnabled: settingsManager.getLatexEnabled(),
            outputPad: settingsManager.getOutputPad(),
            fullscreenWheelScrollLines: settingsManager.getFullscreenWheelScrollLines()
        )
    }
}

@MainActor
public struct InteractiveComposition {
    public let regularChildren: [Component]
    public let transcript: VStack
    public let transcriptScrollView: ScrollView
    public let dock: VStack
    public let fullscreenRoot: VStack

    public init(
        transcriptChildren: [Component],
        pendingMessages: Component,
        status: Component,
        widgets: Component,
        editorSpacer: Component,
        editor: Component,
        footer: Component,
        scrollbar: FullscreenScrollbarMode,
        scrollbarStyle: @escaping (String) -> String
    ) {
        regularChildren = transcriptChildren + [pendingMessages, status, widgets, editorSpacer, editor, footer]
        transcript = VStack(transcriptChildren)
        transcriptScrollView = ScrollView(
            transcript,
            options: ScrollViewOptions(
                follow: .end,
                primary: true,
                overscroll: .chain,
                scrollbar: scrollbar.miniTuiValue,
                scrollbarTrackStyle: { theme.fg(.scrollbarTrack, $0) },
                scrollbarThumbStyle: scrollbarStyle
            )
        )
        dock = VStack(children: [
            .entry(StackEntry(pendingMessages, options: StackEntryOptions(shrink: 1, minSize: 0))),
            .entry(StackEntry(status, options: StackEntryOptions(shrink: 1, minSize: 0))),
            .entry(StackEntry(widgets, options: StackEntryOptions(shrink: 1, minSize: 0))),
            .entry(StackEntry(editorSpacer, options: StackEntryOptions(shrink: 1, minSize: 0))),
            .entry(StackEntry(editor, options: StackEntryOptions(shrink: 1, minSize: 3))),
            .entry(StackEntry(footer, options: StackEntryOptions(shrink: 1, minSize: 0))),
        ])
        fullscreenRoot = VStack(children: [
            .entry(StackEntry(
                transcriptScrollView,
                options: StackEntryOptions(basis: .points(0), grow: 1, shrink: 1, minSize: 1)
            )),
            .entry(StackEntry(
                dock,
                options: StackEntryOptions(basis: .auto, grow: 0, shrink: 1, minSize: 1)
            )),
        ])
    }
}

@MainActor
public func interactiveAltScreenOptions(
    wheelScrollLines: Int? = nil,
    copyOnSelect: Bool = true,
    copySelection: @escaping @MainActor (String) -> PiSwiftCodingAgent.ClipboardCopyResult = copyToClipboard,
    onRightClickPaste: (() -> Void)? = nil,
    openURL: ((String) -> Void)? = nil,
    fullscreenWheelScrollLines: PiSwiftCodingAgent.WheelScrollLines? = nil
) -> AltScreenRendererOptions {
    AltScreenRendererOptions(
        wheelScrollLines: fullscreenWheelScrollLines?.miniTuiValue ?? wheelScrollLines.map { .lines($0) } ?? .auto,
        openURL: openURL ?? { url in
            let process = Process()
            #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            #endif
            process.arguments = [url]
            try? process.run()
        },
        onRightClickPaste: onRightClickPaste,
        searchMatchStyle: { theme.underline(theme.bg(.searchMatchBg, theme.fg(.searchMatchText, $0))) },
        searchCurrentMatchStyle: { theme.bold(theme.inverse(theme.bg(.searchMatchBg, theme.fg(.searchMatchText, $0)))) },
        searchNavigationButtonStyle: { text, hovered in hovered ? theme.underline(text) : text },
        scrollToEndIndicator: {
            let key = formatKeys(getKeybindings().getKeys(TUIKeybinding.altScreenBottom))
            return theme.bg(.selectedBg, theme.fg(.text, " ↓ Jump to latest message" + (key.isEmpty ? "" : " · \(key)") + " "))
        },
        copyOnSelect: copyOnSelect,
        copySelection: { text in
            switch copySelection(text) {
            case .success:
                return .copied
            case .osc52SentUnverified:
                return .failed("Sent a copy request to the terminal; clipboard not verified")
            case .failure(let message):
                return .failed(message)
            }
        }
    )
}

public extension PiSwiftCodingAgent.WheelScrollLines {
    var miniTuiValue: MiniTui.WheelScrollLines {
        switch self {
        case .auto: .auto
        case .lines(let count): .lines(count)
        }
    }

    var displayValue: String {
        switch self {
        case .auto: "auto"
        case .lines(let count): String(count)
        }
    }
}
