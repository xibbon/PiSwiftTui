import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func readLineRange(_ args: [String: AnyCodable], theme: Theme) -> String {
    let hasOffset = args["offset"].map { !($0.value is NSNull) } ?? false
    let hasLimit = args["limit"].map { !($0.value is NSNull) } ?? false
    guard hasOffset || hasLimit else { return "" }
    let start = args["offset"]?.value as? Int ?? 1
    let end = (args["limit"]?.value as? Int).map { start + $0 - 1 }
    return theme.fg(.warning, ":\(start)" + (end != nil && end != 0 ? "-\(end!)" : ""))
}

public func formatPathRelativeToCwdOrAbsolute(_ path: String, cwd: String) -> String {
    let absolute = resolveDisplayPath(path, cwd: cwd)
    let directory = resolveDisplayPath(cwd, cwd: FileManager.default.currentDirectoryPath)
    if absolute == directory { return "." }
    let prefix = directory == "/" ? "/" : directory + "/"
    return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : absolute
}

private func compactReadClassification(_ args: [String: AnyCodable], cwd: String) -> (kind: String, label: String)? {
    guard let rawPath = str(toolPathArgument(args)), !rawPath.isEmpty else { return nil }
    let absolute = resolveToCwd(rawPath, cwd: cwd)
    let file = URL(fileURLWithPath: absolute)
    let name = file.lastPathComponent
    if name == "SKILL.md" {
        let directory = file.deletingLastPathComponent().lastPathComponent
        return ("skill", directory.isEmpty ? name : directory)
    }
    let packageRoot = URL(fileURLWithPath: getReadmePath()).deletingLastPathComponent().path
    let relative = formatPathRelativeToCwdOrAbsolute(absolute, cwd: packageRoot)
    if relative == "README.md" || relative.hasPrefix("docs/") || relative.hasPrefix("examples/") {
        return ("docs", relative)
    }
    // Use the upstream resource names, including its case variants.
    if ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"].contains(name) {
        return ("resource", formatPathRelativeToCwdOrAbsolute(absolute, cwd: cwd))
    }
    return nil
}

@MainActor
public func createReadRenderers() -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        let range = readLineRange(args, theme: theme)
        let output: String
        if !context.expanded, let classification = compactReadClassification(args, cwd: context.cwd) {
            let hint = theme.fg(.dim, " (\(keyText(.expandTools)) to expand)")
            if classification.kind == "skill" {
                output = theme.fg(.customMessageLabel, "\u{1b}[1m[skill]\u{1b}[22m ") + theme.fg(.customMessageText, classification.label) + range + hint
            } else {
                output = theme.fg(.toolTitle, theme.bold("read \(classification.kind)")) + " " + theme.fg(.accent, classification.label) + range + hint
            }
        } else {
            output = theme.fg(.toolTitle, theme.bold("read")) + " " + renderToolPath(str(toolPathArgument(args)), theme, context.cwd) + range
        }
        return toolText(output, context: context)
    }, renderResult: { result, options, theme, context in
        guard options.expanded || context.isError else { return toolText("", context: context) }
        let rawPath = str(toolPathArgument(context.args))
        let lang = !context.isError ? rawPath.flatMap { $0.isEmpty ? nil : getLanguageFromPath($0) } : nil
        let output = getTextOutput(result, showImages: context.showImages)
        let rendered = lang.map { highlightCode(replaceTabs(output), lang: $0) } ?? output.components(separatedBy: "\n")
        let lines = trimToolTrailingEmptyLines(rendered)
        let visible = options.expanded ? lines : Array(lines.prefix(10))
        var text = "\n" + visible.map { lang != nil ? replaceTabs($0) : theme.fg(.toolOutput, replaceTabs($0)) }.joined(separator: "\n")
        if visible.count < lines.count { text += toolMoreLinesHint(lines.count - visible.count, theme: theme) }
        if let truncation = toolDetails(result)["truncation"] as? [String: Any], truncation["truncated"] as? Bool == true {
            let maxBytes = truncation["maxBytes"] as? Int ?? DEFAULT_MAX_BYTES
            let outputLines = truncation["outputLines"] as? Int ?? 0
            let warning: String
            if truncation["firstLineExceedsLimit"] as? Bool == true {
                warning = "[First line exceeds \(formatSize(maxBytes)) limit]"
            } else if truncation["truncatedBy"] as? String == "lines" {
                warning = "[Truncated: showing \(outputLines) of \(truncation["totalLines"] as? Int ?? 0) lines (\(truncation["maxLines"] as? Int ?? DEFAULT_MAX_LINES) line limit)]"
            } else {
                warning = "[Truncated: \(outputLines) lines shown (\(formatSize(maxBytes)) limit)]"
            }
            text += "\n" + theme.fg(.warning, warning)
        }
        return toolText(text, context: context)
    })
}
