import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Shell tools use the same renderer with a different prompt.
@MainActor
public func createShellRenderers(prompt: String) -> ToolRenderers {
    ToolRenderers(
        renderCall: { args, theme, context in
            startToolTimer(context)
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
            let timerText = toolTimerText(context, isPartial: options.isPartial)
            let component = (context.lastComponent as? Container) ?? Container()
            component.clear()
            var output = getTextOutput(result, showImages: context.showImages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let details = toolDetails(result)
            let truncation = details["truncation"] as? [String: Any] ?? [:]
            let truncated = truncation["truncated"] as? Bool == true
            let fullOutputPath = details["fullOutputPath"] as? String
            if !options.isPartial, truncated, let fullOutputPath, output.hasSuffix("]"),
               let footer = output.range(of: "\n\n[", options: .backwards),
               output[footer.lowerBound...].contains(fullOutputPath) {
                output = String(output[..<footer.lowerBound]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            if !output.isEmpty {
                let styled = output.components(separatedBy: "\n").map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
                if options.expanded {
                    component.addChild(Text("\n" + styled, paddingX: 0, paddingY: 0))
                } else {
                    component.addChild(Spacer(1))
                    component.addChild(VisualLinePreview(text: styled, maxVisualLines: 5, keep: .end) { hidden in
                        theme.fg(.muted, "... (\(hidden) earlier lines,")
                            + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
                    })
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
            if let timerText {
                component.addChild(Text("\n" + theme.fg(.muted, timerText), paddingX: 0, paddingY: 0))
            }
            component.invalidate()
            return component
        }
    )
}

func formatShellDuration(_ seconds: TimeInterval) -> String {
    formatToolDuration(seconds)
}
