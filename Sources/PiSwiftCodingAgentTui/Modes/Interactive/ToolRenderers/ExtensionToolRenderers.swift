import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
public func createMcpRenderers(label: String) -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        toolText(formatToolCallWithArgs(label, args: args, theme: theme, expanded: context.expanded), context: context)
    }, renderResult: { result, options, theme, context in
        let component = (context.lastComponent as? Container) ?? Container()
        component.clear()
        let output = getTextOutput(result, showImages: context.showImages).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return component }
        let styled = replaceTabs(output).components(separatedBy: "\n")
            .map { theme.fg(context.isError ? .error : .toolOutput, $0) }.joined(separator: "\n")
        component.addChild(Spacer(1))
        if options.expanded {
            component.addChild(Text(styled, paddingX: 0, paddingY: 0))
        } else {
            component.addChild(VisualLinePreview(text: styled, maxVisualLines: 5, keep: .start) { hidden in
                codemodeExpandHint(hidden, theme: theme)
            })
            if let path = toolDetails(result)["fullOutputPath"] as? String, !path.isEmpty {
                component.addChild(Text(theme.fg(.muted, "Full output: \(path)"), paddingX: 0, paddingY: 0))
            }
        }
        return component
    })
}

private func codemodeExpandHint(_ hidden: Int, theme: Theme) -> String {
    theme.fg(.muted, "... (\(hidden) more lines,") + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
}

func codemodeCost(_ cost: Double) -> String {
    if cost >= 0.01 { return String(format: "$%.2f", cost) }
    // toPrecision(2) keeps two significant digits, including trailing zeros.
    guard cost != 0 else { return "$0.0" }
    let scientific = String(format: "%.1e", cost).components(separatedBy: "e")
    let exponent = Int(scientific[1]) ?? 0
    let rounded = Double(scientific.joined(separator: "e")) ?? cost
    if exponent < -6 || exponent >= 2 {
        return "$" + scientific[0] + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }
    return String(format: "$%.*f", max(0, 1 - exponent), rounded)
}

private func codemodeCall(_ call: [String: Any], theme: Theme, expanded: Bool) -> String {
    let icon: String
    switch call["status"] as? String {
    case "running": icon = theme.fg(.warning, "…")
    case "ok": icon = theme.fg(.success, "✓")
    case "error": icon = theme.fg(.error, "✗")
    default: icon = theme.fg(.muted, "⊘")
    }
    let args = call["args"] as? String ?? ""
    var line = icon + " " + theme.fg(.toolTitle, call["name"] as? String ?? "")
    if !args.isEmpty { line += " " + theme.fg(.muted, expanded ? args : toolPreview(args, maxCharacters: 80)) }
    if let ms = (call["durationMs"] as? NSNumber)?.doubleValue {
        let duration = ms < 1000 ? "\(Int(floor(ms + 0.5)))ms" : String(format: "%.1fs", ms / 1000)
        line += " " + theme.fg(.dim, duration)
    }
    if let cost = (call["cost"] as? NSNumber)?.doubleValue, cost != 0 { line += " " + theme.fg(.dim, codemodeCost(cost)) }
    if expanded, let error = call["error"] as? String, !error.isEmpty {
        line += "\n    " + theme.fg(.error, error.replacingOccurrences(of: "\n", with: "\n    "))
    }
    return line
}

@MainActor
public func createCodemodeRenderers() -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        let title = theme.fg(.toolTitle, theme.bold("codemode"))
        let component = (context.lastComponent as? Container) ?? Container()
        component.clear()
        guard let code = str(args["code"]) else {
            component.addChild(Text(title + " " + invalidArgText(theme), paddingX: 0, paddingY: 0))
            return component
        }
        component.addChild(Text(title, paddingX: 0, paddingY: 0))
        if !code.isEmpty {
            let normalized = normalizeDisplayText(code).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let highlighted = highlightCode(replaceTabs(normalized), lang: "javascript").joined(separator: "\n")
            if context.expanded {
                component.addChild(Text(highlighted, paddingX: 0, paddingY: 0))
            } else {
                component.addChild(VisualLinePreview(text: highlighted, maxVisualLines: 10, keep: .start) { hidden in
                    codemodeExpandHint(hidden, theme: theme)
                })
            }
        }
        return component
    }, renderResult: { result, options, theme, context in
        let component = (context.lastComponent as? Container) ?? Container()
        component.clear()
        let details = toolDetails(result)
        let calls = details["calls"] as? [[String: Any]] ?? []
        if !calls.isEmpty {
            let shown = options.expanded ? calls : Array(calls.suffix(8))
            var lines = shown.map { codemodeCall($0, theme: theme, expanded: options.expanded) }
            if shown.count < calls.count {
                lines.insert(theme.fg(.muted, "... (\(calls.count - shown.count) earlier calls,") + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")"), at: 0)
            }
            let priced = calls.compactMap { ($0["cost"] as? NSNumber)?.doubleValue }.filter { $0 != 0 }
            if priced.count > 1 { lines.append(theme.fg(.muted, "Model calls: " + codemodeCost(priced.reduce(0, +)))) }
            component.addChild(Spacer(1))
            component.addChild(Text(lines.joined(separator: "\n"), paddingX: 0, paddingY: 0))
        }
        var content = result.content
        if case .text(let first) = content.first,
           first.text.range(of: #"\AScript (completed|failed)\nWall time [\d.]+ seconds\nOutput:\n\z"#, options: .regularExpression) != nil {
            content.removeFirst()
        }
        let output = options.isPartial ? "" : getTextOutput(AgentToolResult(content: content), showImages: context.showImages).trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            let styled = replaceTabs(output).components(separatedBy: "\n")
                .map { theme.fg(context.isError ? .error : .toolOutput, $0) }.joined(separator: "\n")
            component.addChild(Spacer(1))
            if options.expanded {
                component.addChild(Text(styled, paddingX: 0, paddingY: 0))
            } else {
                component.addChild(VisualLinePreview(text: styled, maxVisualLines: 5, keep: .start) { hidden in
                    codemodeExpandHint(hidden, theme: theme)
                })
                if let path = details["fullOutputPath"] as? String, !path.isEmpty {
                    component.addChild(Text(theme.fg(.muted, "Full output: \(path)"), paddingX: 0, paddingY: 0))
                }
            }
        }
        return component
    })
}
