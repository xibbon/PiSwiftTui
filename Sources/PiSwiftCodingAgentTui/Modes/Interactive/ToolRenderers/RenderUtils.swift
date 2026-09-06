import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

public func shortenPath(_ path: Any?) -> String {
    guard let path = path as? String else { return "" }
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

public func linkPath(_ styledText: String, rawPath: String, cwd: String) -> String {
    guard getCapabilities().hyperlinks else { return styledText }
    return hyperlink(styledText, url: URL(fileURLWithPath: resolveDisplayPath(rawPath, cwd: cwd)).absoluteString)
}

// The upstream display resolver also accepts file URLs and normalizes dot segments.
func resolveDisplayPath(_ rawPath: String, cwd: String) -> String {
    func expand(_ path: String) -> String {
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url.path }
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
        return path
    }
    let path = expand(rawPath)
    let base = URL(fileURLWithPath: expand(cwd), isDirectory: true)
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    return url.standardizedFileURL.path
}

func toolPathArgument(_ args: [String: AnyCodable]) -> AnyCodable? {
    if let alias = args["file_path"], !(alias.value is NSNull) { return alias }
    return args["path"]
}

/// Missing and null arguments are empty strings. Other non-string arguments are invalid.
public func str(_ value: AnyCodable?) -> String? {
    guard let value, !(value.value is NSNull) else { return "" }
    return value.value as? String
}

public func replaceTabs(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: "   ")
}

public func normalizeDisplayText(_ text: String) -> String {
    text.replacingOccurrences(of: "\r", with: "")
}

// ANSI expression derived from ansi-regex and strip-ansi through upstream utils/ansi.ts.
// Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com).
// MIT License; see LICENSE for the permission notice and warranty disclaimer.
/// Remove terminal control sequences before binary-output sanitization removes ESC bytes.
func stripToolAnsi(_ text: String) -> String {
    let pattern = #"(?:\x1B\][\s\S]*?(?:\x07|\x1B\\|\x{009C}))|[\x1B\x{009B}][\[\]()#;?]*(?:\d{1,4}(?:[;:]\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]"#
    return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
}

public func getTextOutput(_ result: AgentToolResult?, showImages: Bool) -> String {
    guard let result else { return "" }
    var output = result.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return normalizeDisplayText(sanitizeBinaryOutput(stripToolAnsi(text.text)))
    }.joined(separator: "\n")
    if getCapabilities().images == nil || !showImages {
        let indicators = result.content.compactMap { block -> String? in
            guard case .image(let image) = block else { return nil }
            return imageFallback(image.mimeType, dimensions: getImageDimensions(image.data, mimeType: image.mimeType), filename: nil)
        }.joined(separator: "\n")
        if !indicators.isEmpty { output += (output.isEmpty ? "" : "\n") + indicators }
    }
    return output
}

public func invalidArgText(_ theme: Theme) -> String {
    theme.fg(.error, "[invalid arg]")
}

public func renderToolPath(_ rawPath: String?, _ theme: Theme, _ cwd: String, emptyFallback: String? = nil) -> String {
    guard let rawPath else { return invalidArgText(theme) }
    let value = rawPath.isEmpty ? emptyFallback : rawPath
    guard let value, !value.isEmpty else { return theme.fg(.toolOutput, "...") }
    return linkPath(theme.fg(.accent, shortenPath(value)), rawPath: value, cwd: cwd)
}

@MainActor
func toolText(_ value: String, context: ToolRenderContext) -> Text {
    let text = context.lastComponent as? Text ?? Text("", paddingX: 0, paddingY: 0)
    text.setText(value)
    return text
}

func toolDetails(_ result: AgentToolResult) -> [String: Any] {
    result.details?.value as? [String: Any] ?? [:]
}

func trimToolTrailingEmptyLines(_ lines: [String]) -> [String] {
    var lines = lines
    while lines.last == "" { lines.removeLast() }
    return lines
}

func toolMoreLinesHint(_ count: Int, theme: Theme) -> String {
    theme.fg(.muted, "\n... (\(count) more lines,") + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
}

func toolArgumentDisplay(_ value: AnyCodable) -> String {
    if value.value is NSNull { return "null" }
    return String(describing: value.value)
}

/// Shared output layout for grep, find, and ls.
func formatSearchToolResult(_ result: AgentToolResult, options: RenderResultOptions, theme: Theme, showImages: Bool, lineLimit: Int, limitKey: String, limitLabel: String, includeLinesTruncated: Bool = false) -> String {
    let output = getTextOutput(result, showImages: showImages).trimmingCharacters(in: .whitespacesAndNewlines)
    var text = ""
    if !output.isEmpty {
        let lines = output.components(separatedBy: "\n")
        let visible = options.expanded ? lines : Array(lines.prefix(lineLimit))
        text = "\n" + visible.map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
        if visible.count < lines.count { text += toolMoreLinesHint(lines.count - visible.count, theme: theme) }
    }
    let details = toolDetails(result)
    let truncation = details["truncation"] as? [String: Any] ?? [:]
    var warnings: [String] = []
    if let limit = details[limitKey] as? Int, limit != 0 { warnings.append("\(limit) \(limitLabel) limit") }
    if truncation["truncated"] as? Bool == true { warnings.append("\(formatSize(truncation["maxBytes"] as? Int ?? DEFAULT_MAX_BYTES)) limit") }
    if includeLinesTruncated && details["linesTruncated"] as? Bool == true { warnings.append("some lines truncated") }
    if !warnings.isEmpty { text += "\n" + theme.fg(.warning, "[Truncated: \(warnings.joined(separator: ", "))]") }
    return text
}
