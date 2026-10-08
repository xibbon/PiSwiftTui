import Foundation
import MiniTui
import PiSwiftCodingAgent

private let previewLines = 20

@MainActor
public final class BashExecutionComponent: Container, OutputPaddingSetting {
    private let command: String
    private let colorKey: ThemeColor
    private var outputPad: Int
    private var outputLines: [String] = []
    private var status: String = "running"
    private var exitCode: Int?
    private let loader: Loader
    private var truncationResult: TruncationResult?
    private var fullOutputPath: String?
    private var expanded = false
    private let contentContainer: Container
    private let ui: TUI

    public init(command: String, ui: TUI, excludeFromContext: Bool = false, outputPad: Int = 1) {
        self.command = command
        self.ui = ui
        let colorKey: ThemeColor = excludeFromContext ? .dim : .bashMode
        self.colorKey = colorKey
        self.outputPad = outputPad
        let borderColor: (String) -> String = { theme.fg(colorKey, $0) }

        self.contentContainer = Container()
        self.loader = Loader(
            ui: ui,
            spinnerColorFn: { theme.fg(colorKey, $0) },
            messageColorFn: { theme.fg(.muted, $0) },
            message: "Running... (esc to cancel)"
        )

        super.init()

        addChild(Spacer(1))
        addChild(DynamicBorder(color: borderColor))
        addChild(contentContainer)
        addChild(DynamicBorder(color: borderColor))

        updateDisplay()
    }

    public override func invalidate() {
        super.invalidate()
        updateDisplay()
    }

    public func setOutputPad(_ outputPad: Int) {
        self.outputPad = outputPad
        updateDisplay()
    }

    public func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        updateDisplay()
    }

    public func appendOutput(_ chunk: String) {
        let clean = stripAnsi(chunk)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let newLines = clean.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !outputLines.isEmpty, let first = newLines.first {
            outputLines[outputLines.count - 1] += first
            outputLines.append(contentsOf: newLines.dropFirst())
        } else {
            outputLines.append(contentsOf: newLines)
        }

        updateDisplay()
    }

    public func setComplete(
        exitCode: Int?,
        cancelled: Bool,
        truncationResult: TruncationResult? = nil,
        fullOutputPath: String? = nil
    ) {
        self.exitCode = exitCode
        self.status = cancelled ? "cancelled" : ((exitCode ?? 0) != 0 ? "error" : "complete")
        self.truncationResult = truncationResult
        self.fullOutputPath = fullOutputPath

        loader.stop()
        updateDisplay()
    }

    private func updateDisplay() {
        let fullOutput = outputLines.joined(separator: "\n")
        let contextTruncation = truncateTail(fullOutput, options: TruncationOptions(maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES))
        let availableLines = contextTruncation.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let previewLogicalLines = Array(availableLines.suffix(previewLines))
        let hiddenLineCount = max(0, availableLines.count - previewLogicalLines.count)

        contentContainer.clear()

        let header = Text(theme.fg(colorKey, theme.bold("$ \(command)")), paddingX: outputPad, paddingY: 0)
        contentContainer.addChild(header)

        if !availableLines.isEmpty {
            if expanded {
                let displayText = availableLines.map { theme.fg(.muted, $0) }.joined(separator: "\n")
                contentContainer.addChild(Text("\n" + displayText, paddingX: outputPad, paddingY: 0))
            } else {
                let styledOutput = previewLogicalLines.map { theme.fg(.muted, $0) }.joined(separator: "\n")
                contentContainer.addChild(BashOutputPreview(text: "\n" + styledOutput, paddingX: outputPad))
            }
        }

        if status == "running" {
            contentContainer.addChild(loader)
            return
        }

        var statusParts: [String] = []
        if hiddenLineCount > 0 {
            if expanded {
                statusParts.append(theme.fg(.dim, "(ctrl+o to collapse)"))
            } else {
                statusParts.append(theme.fg(.dim, "... \(hiddenLineCount) more lines (ctrl+o to expand)"))
            }
        }

        if status == "cancelled" {
            statusParts.append(theme.fg(.warning, "(cancelled)"))
        } else if status == "error" {
            statusParts.append(theme.fg(.error, "(exit \(exitCode ?? 0))"))
        }

        let wasTruncated = (truncationResult?.truncated ?? false) || contextTruncation.truncated
        if wasTruncated, let fullOutputPath {
            statusParts.append(theme.fg(.warning, "Output truncated. Full output: \(fullOutputPath)"))
        }

        if !statusParts.isEmpty {
            contentContainer.addChild(Text("\n" + statusParts.joined(separator: "\n"), paddingX: outputPad, paddingY: 0))
        }
    }

    public func getOutput() -> String {
        outputLines.joined(separator: "\n")
    }

    public func getCommand() -> String {
        command
    }
}

private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[mGKHJ]", with: "", options: .regularExpression)
}

@MainActor
private final class BashOutputPreview: Component {
    private let text: String
    private let paddingX: Int
    private var cachedWidth: Int?
    private var cachedLines: [String] = []

    init(text: String, paddingX: Int) {
        self.text = text
        self.paddingX = paddingX
    }

    func render(width: Int) -> [String] {
        if cachedWidth != width {
            cachedLines = truncateToVisualLines(text, maxVisualLines: previewLines, width: width, paddingX: paddingX).visualLines
            cachedWidth = width
        }
        return cachedLines
    }
}
