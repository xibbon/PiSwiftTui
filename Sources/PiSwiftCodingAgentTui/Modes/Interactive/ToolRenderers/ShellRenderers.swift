import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
private final class ShellRenderState {
    var startedAt: Date?
    var endedAt: Date?
    var timer: Task<Void, Never>?

    deinit { timer?.cancel() }
}

@MainActor
private final class ShellOutputPreview: Component {
    let output: String
    let theme: Theme
    private var cachedWidth: Int?
    private var cachedPreview: VisualTruncateResult?

    init(output: String, theme: Theme) {
        self.output = output
        self.theme = theme
    }

    func render(width: Int) -> [String] {
        if cachedWidth != width || cachedPreview == nil {
            cachedPreview = truncateToVisualLines(output, maxVisualLines: 5, width: width)
            cachedWidth = width
        }
        guard let preview = cachedPreview else { return [] }
        if preview.skippedCount > 0 {
            let hint = theme.fg(.muted, "... (\(preview.skippedCount) earlier lines,")
                + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
            return ["", truncateToWidth(hint, maxWidth: width, ellipsis: "...")] + preview.visualLines
        }
        return [""] + preview.visualLines
    }

    func invalidate() {
        cachedWidth = nil
        cachedPreview = nil
    }
}

/// Shell tools use the same renderer with a different prompt.
@MainActor
public func createShellRenderers(prompt: String) -> ToolRenderers {
    ToolRenderers(
        renderCall: { args, theme, context in
            let state = shellState(context)
            if context.executionStarted && state.startedAt == nil {
                state.startedAt = Date()
                state.endedAt = nil
            }
            let command = str(args["command"])
            let display = command.map { $0.isEmpty ? theme.fg(.toolOutput, "...") : $0 }
                ?? invalidArgText(theme)
            var output = theme.fg(.toolTitle, theme.bold("\(prompt) \(display)"))
            if let timeout = args["timeout"]?.value as? NSNumber, timeout.doubleValue != 0 {
                output += theme.fg(.muted, " (timeout \(timeout.stringValue)s)")
            }
            let component = (context.lastComponent as? Text) ?? Text("", paddingX: 0, paddingY: 0)
            component.setText(output)
            return component
        },
        renderResult: { result, options, theme, context in
            let state = shellState(context)
            if state.startedAt != nil && options.isPartial && !context.isError && state.timer == nil {
                let invalidate = context.invalidate
                state.timer = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { break }
                        guard !Task.isCancelled else { break }
                        invalidate()
                    }
                }
            }
            if !options.isPartial || context.isError {
                if state.endedAt == nil { state.endedAt = Date() }
                state.timer?.cancel()
                state.timer = nil
            }
            let component = (context.lastComponent as? Container) ?? Container()
            component.clear()
            var output = getTextOutput(result, showImages: context.showImages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let details = toolDetails(result)
            let truncation = details["truncation"] as? [String: Any] ?? [:]
            let truncated = truncation["truncated"] as? Bool == true
            let fullOutputPath = details["fullOutputPath"] as? String
            if !options.isPartial, let fullOutputPath, output.hasSuffix("]"),
               let footer = output.range(of: "\n\n[", options: .backwards),
               output[footer.lowerBound...].contains("Full output: \(fullOutputPath)") {
                output = String(output[..<footer.lowerBound]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            if !output.isEmpty {
                let styled = output.components(separatedBy: "\n").map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
                if options.expanded {
                    component.addChild(Text("\n" + styled, paddingX: 0, paddingY: 0))
                } else {
                    component.addChild(ShellOutputPreview(output: styled, theme: theme))
                }
            }
            if truncated || fullOutputPath != nil {
                var warnings: [String] = []
                if let fullOutputPath { warnings.append("Full output: \(fullOutputPath)") }
                if truncated {
                    let outputLines = truncation["outputLines"] as? Int ?? 0
                    if truncation["truncatedBy"] as? String == "lines" {
                        warnings.append("Truncated: showing \(outputLines) of \(truncation["totalLines"] as? Int ?? 0) lines")
                    } else {
                        warnings.append("Truncated: \(outputLines) lines shown (\(formatSize(truncation["maxBytes"] as? Int ?? DEFAULT_MAX_BYTES)) limit)")
                    }
                }
                component.addChild(Text("\n" + theme.fg(.warning, "[\(warnings.joined(separator: ". "))]"), paddingX: 0, paddingY: 0))
            }
            if let startedAt = state.startedAt {
                let duration = formatShellDuration((state.endedAt ?? Date()).timeIntervalSince(startedAt))
                let label = options.isPartial && !context.isError ? "Elapsed" : "Took"
                component.addChild(Text("\n" + theme.fg(.muted, "\(label) \(duration)"), paddingX: 0, paddingY: 0))
            }
            component.invalidate()
            return component
        }
    )
}

func formatShellDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds)
    let minutes = whole / 60
    let remainingSeconds = whole % 60
    if minutes < 60 { return "\(minutes)m \(remainingSeconds)s" }
    return "\(minutes / 60)h \(minutes % 60)m \(remainingSeconds)s"
}

@MainActor
private func shellState(_ context: ToolRenderContext) -> ShellRenderState {
    if let state = context.state.values["shell"] as? ShellRenderState { return state }
    let state = ShellRenderState()
    context.state.values["shell"] = state
    return state
}
