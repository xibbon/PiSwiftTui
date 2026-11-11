import Foundation
import MiniTui
import PiSwiftCodingAgent
import Synchronization

private struct MermaidCacheEntry: Sendable {
    let source: String
    let width: Int
    let themeKey: String
    let hyperlinks: Bool
    let result: String
}

public struct MermaidMarkdownTransformOptions: Sendable {
    public var enabled: Bool
    public var renderWhileStreaming: Bool
    public var isStreaming: Bool
    public var theme: Theme?

    public init(
        enabled: Bool = true,
        renderWhileStreaming: Bool = true,
        isStreaming: Bool = false,
        theme: Theme? = nil
    ) {
        self.enabled = enabled
        self.renderWhileStreaming = renderWhileStreaming
        self.isStreaming = isStreaming
        self.theme = theme
    }
}

private struct MermaidNode: Sendable {
    let id: String
    let label: String
    let style: MermaidAuthoredStyle?
    let href: String?
}

private struct MermaidDiagram: Sendable {
    enum Direction: Sendable {
        case horizontal
        case vertical
    }

    let direction: Direction
    let nodes: [MermaidNode]
}

private struct MermaidFence {
    let character: Character
    let length: Int
    let start: Int
    let end: Int
    let body: String
    let closed: Bool
}

/// Create a MiniTui Markdown source transform for Mermaid fenced code blocks.
public func createMermaidMarkdownTransform(
    options: MermaidMarkdownTransformOptions
) -> MarkdownSourceTransform {
    let cache = Mutex<MermaidCacheEntry?>(nil)
    return { source, width in
        guard options.enabled,
              !options.isStreaming || options.renderWhileStreaming else {
            return source
        }
        let hyperlinks = getCapabilities().hyperlinks
        let themeKey = options.theme.map {
            $0.getFgAnsi(.borderMuted) + $0.getFgAnsi(.text) + $0.getFgAnsi(.accent)
        } ?? ""
        if let hit = cache.withLock({ $0 }), hit.source == source, hit.width == width,
           hit.themeKey == themeKey, hit.hyperlinks == hyperlinks {
            return hit.result
        }
        let result = transformMermaidFences(source, width: width, options: options)
        if source.utf8.count + result.utf8.count <= 1_048_576 {
            cache.withLock { $0 = MermaidCacheEntry(source: source, width: width,
                themeKey: themeKey, hyperlinks: hyperlinks, result: result) }
        }
        return result
    }
}

private func transformMermaidFences(
    _ source: String,
    width: Int,
    options: MermaidMarkdownTransformOptions
) -> String {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var output: [String] = []
    var index = 0
    var replacedAtEnd = false

    while index < lines.count {
        guard let fence = mermaidFence(lines: lines, start: index, allowUnclosed: options.isStreaming) else {
            output.append(lines[index])
            replacedAtEnd = false
            index += 1
            continue
        }

        let original = lines[fence.start...fence.end].joined(separator: "\n")
        let safeBody = String(String.UnicodeScalarView(fence.body.unicodeScalars.filter { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 ||
                (value >= 32 && value != 127 && !(128...159).contains(value))
        }))
        let pie = renderMermaidPie(safeBody, theme: options.theme)
        let presentation = mermaidFlowPresentation(safeBody)
        var rendered = pie?.lines ?? parseMermaidDiagram(presentation.source)
            .flatMap { renderMermaidDiagram($0, theme: options.theme, presentation: presentation) }
        if options.isStreaming, rendered != nil {
            for label in presentation.orphanLabels {
                rendered?.append("")
                rendered?.append("┌" + String(repeating: "─", count: label.count + 2) + "┐")
                rendered?.append("│ \(label) │")
                rendered?.append("└" + String(repeating: "─", count: label.count + 2) + "┘")
            }
        }
        guard let rendered,
              rendered.allSatisfy({ visibleWidth($0) <= width }) else {
            output.append(original)
            replacedAtEnd = false
            index = fence.end + 1
            continue
        }

        let warnings = pie?.warnings ?? presentation.warnings
        if let warning = warnings.first, !options.isStreaming {
            let suffix = warnings.count > 1 ? " (+\(warnings.count - 1) more)" : ""
            let notice = "Mermaid diagram not rendered: \(warning)\(suffix)"
            output.append(original + "\n" + markdownCodeSpan(options.theme?.fg(.warning, notice) ?? notice) + "  ")
        } else {
            output.append(rendered.map(markdownCodeSpan).joined(separator: "  \n"))
        }
        replacedAtEnd = true
        index = fence.end + 1
    }

    let transformed = output.joined(separator: "\n")
    return replacedAtEnd ? transformed + "\n" : transformed
}

private func mermaidFence(lines: [String], start: Int, allowUnclosed: Bool) -> MermaidFence? {
    let line = lines[start]
    let leadingSpaces = line.prefix { $0 == " " }.count
    guard leadingSpaces <= 3 else { return nil }
    let trimmed = String(line.dropFirst(leadingSpaces))
    guard let character = trimmed.first, character == "`" || character == "~" else { return nil }
    let length = trimmed.prefix { $0 == character }.count
    guard length >= 3 else { return nil }
    let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
    guard info.split(whereSeparator: \Character.isWhitespace).first?.lowercased() == "mermaid" else {
        return nil
    }

    var end = start + 1
    while end < lines.count {
        let candidate = lines[end].trimmingCharacters(in: .whitespaces)
        let candidateLength = candidate.prefix { $0 == character }.count
        if candidateLength >= length,
           candidate.dropFirst(candidateLength).trimmingCharacters(in: .whitespaces).isEmpty {
            return MermaidFence(
                character: character,
                length: length,
                start: start,
                end: end,
                body: lines[(start + 1)..<end].joined(separator: "\n"),
                closed: true
            )
        }
        end += 1
    }

    guard allowUnclosed else { return nil }
    return MermaidFence(
        character: character,
        length: length,
        start: start,
        end: lines.count - 1,
        body: lines[(start + 1)...].joined(separator: "\n"),
        closed: false
    )
}

private func parseMermaidDiagram(_ source: String) -> MermaidDiagram? {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    guard let header = lines.first else { return nil }
    let headerParts = header.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard headerParts.count >= 2,
          headerParts[0].lowercased() == "flowchart" || headerParts[0].lowercased() == "graph" else {
        return nil
    }

    let direction: MermaidDiagram.Direction
    switch headerParts[1].uppercased() {
    case "LR", "RL": direction = .horizontal
    case "TB", "TD", "BT": direction = .vertical
    default: return nil
    }

    var nodes: [MermaidNode] = []
    var nodeIndices: [String: Int] = [:]
    var edges: [(String, String)] = []

    func addNode(_ token: String) -> String? {
        guard let node = parseMermaidNode(token) else { return nil }
        if let existing = nodeIndices[node.id] {
            if nodes[existing].label == nodes[existing].id, node.label != node.id {
                nodes[existing] = node
            }
        } else {
            nodeIndices[node.id] = nodes.count
            nodes.append(node)
        }
        return node.id
    }

    for line in lines.dropFirst() {
        guard let arrowRange = mermaidArrowRange(in: line) else { return nil }
        let left = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var right = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if right.hasPrefix("|") {
            guard let close = right.dropFirst().firstIndex(of: "|") else { return nil }
            right = String(right[right.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let leftID = addNode(left), let rightID = addNode(right) else { return nil }
        edges.append((leftID, rightID))
    }

    guard !edges.isEmpty, nodes.count == edges.count + 1 else { return nil }
    for index in edges.indices {
        guard edges[index].0 == nodes[index].id, edges[index].1 == nodes[index + 1].id else {
            return nil
        }
    }

    if headerParts[1].uppercased() == "RL" || headerParts[1].uppercased() == "BT" {
        nodes.reverse()
    }
    return MermaidDiagram(direction: direction, nodes: nodes)
}

private func mermaidArrowRange(in line: String) -> Range<String.Index>? {
    for arrow in ["-->", "==>", "-.->"] {
        if let range = line.range(of: arrow) { return range }
    }
    return nil
}

private func parseMermaidNode(_ token: String) -> MermaidNode? {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first.isLetter || first == "_" else { return nil }
    let id = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    guard !id.isEmpty else { return nil }
    let remainder = trimmed.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
    if remainder.isEmpty {
        return MermaidNode(id: String(id), label: String(id), style: nil, href: nil)
    }

    let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("{", "}")]
    guard let opening = remainder.first,
          let closing = pairs.first(where: { $0.0 == opening })?.1,
          remainder.last == closing else {
        return nil
    }
    var label = String(remainder.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    if label.hasPrefix("\"") && label.hasSuffix("\"") && label.count >= 2 {
        label = String(label.dropFirst().dropLast())
    }
    guard !label.isEmpty, !label.contains("[") && !label.contains("]") else { return nil }
    return MermaidNode(id: String(id), label: label, style: nil, href: nil)
}

private func renderMermaidDiagram(_ diagram: MermaidDiagram, theme: Theme?, presentation: MermaidFlowPresentation) -> [String]? {
    guard !diagram.nodes.isEmpty else { return nil }
    let nodes = diagram.nodes.map { MermaidNode(id: $0.id, label: $0.label,
        style: presentation.styles[$0.id], href: presentation.links[$0.id]) }
    switch diagram.direction {
    case .horizontal:
        return renderHorizontalMermaid(nodes, theme: theme, edgeStyles: presentation.edgeStyles)
    case .vertical:
        return renderVerticalMermaid(nodes, theme: theme, edgeStyles: presentation.edgeStyles)
    }
}

private func renderHorizontalMermaid(_ nodes: [MermaidNode], theme: Theme?, edgeStyles: [Int: MermaidAuthoredStyle]) -> [String] {
    let tops = nodes.map { styledBorder("┌" + String(repeating: "─", count: $0.label.count + 2) + "┐", theme, style: $0.style) }
    let bottoms = nodes.map { styledBorder("└" + String(repeating: "─", count: $0.label.count + 2) + "┘", theme, style: $0.style) }
    var middle = ""
    for index in nodes.indices {
        let node = nodes[index]
        middle += styledBorder("│", theme, style: node.style) + styledNodeSpace(node, theme: theme)
            + linkedText(node, theme: theme) + styledNodeSpace(node, theme: theme)
        if index == nodes.count - 1 {
            middle += styledBorder("│", theme, style: node.style)
        } else {
            middle += styledBorder("├", theme, style: node.style) + styledEdge("───▶", theme, style: edgeStyles[index])
        }
    }
    return [tops.joined(separator: "    "), middle, bottoms.joined(separator: "    ")]
}

private func renderVerticalMermaid(_ nodes: [MermaidNode], theme: Theme?, edgeStyles: [Int: MermaidAuthoredStyle]) -> [String] {
    let maxWidth = nodes.map { $0.label.count + 2 }.max() ?? 2
    var lines: [String] = []
    for index in nodes.indices {
        let node = nodes[index]
        let left = (maxWidth - node.label.count) / 2
        let right = maxWidth - node.label.count - left
        lines.append(styledBorder("┌" + String(repeating: "─", count: maxWidth) + "┐", theme, style: node.style))
        lines.append(
            styledBorder("│", theme, style: node.style)
                + String(repeating: " ", count: left)
                + linkedText(node, theme: theme)
                + String(repeating: " ", count: right)
                + styledBorder("│", theme, style: node.style)
        )
        lines.append(styledBorder("└" + String(repeating: "─", count: maxWidth) + "┘", theme, style: node.style))
        if index < nodes.count - 1 {
            let indent = String(repeating: " ", count: (maxWidth + 1) / 2)
            lines.append(indent + styledEdge("│", theme, style: edgeStyles[index]))
            lines.append(indent + styledEdge("▼", theme, style: edgeStyles[index]))
        }
    }
    return lines
}

private func styledBorder(_ text: String, _ theme: Theme?, style: MermaidAuthoredStyle? = nil) -> String {
    if let style, let theme,
       let authored = style.apply(text, border: true, fallback: theme.getFgAnsi(.borderMuted)) {
        return authored
    }
    return theme?.fg(.borderMuted, text) ?? text
}

private func styledText(_ text: String, _ theme: Theme?) -> String {
    theme?.fg(.text, text) ?? text
}

private func styledEdge(_ text: String, _ theme: Theme?, style: MermaidAuthoredStyle? = nil) -> String {
    if let style, let theme,
       let authored = style.apply(text, border: true, fallback: theme.getFgAnsi(.accent)) {
        return authored
    }
    return theme?.fg(.accent, text) ?? text
}

private func linkedText(_ node: MermaidNode, theme: Theme?) -> String {
    let authored = node.style.flatMap { style in
        theme.flatMap { style.apply(node.label, border: false, fallback: $0.getFgAnsi(.text)) }
    }
    let text = authored ?? styledText(node.label, theme)
    guard theme != nil, getCapabilities().hyperlinks, let href = node.href else { return text }
    return "\u{1B}]8;;\(href)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
}

private func styledNodeSpace(_ node: MermaidNode, theme: Theme?) -> String {
    guard let theme, let style = node.style else { return " " }
    return style.apply(" ", border: false, fallback: theme.getFgAnsi(.text)) ?? " "
}

private func markdownCodeSpan(_ line: String) -> String {
    let content = line.isEmpty ? "\u{00A0}" : line
    var longestRun = 0
    var currentRun = 0
    for character in content {
        if character == "`" {
            currentRun += 1
            longestRun = max(longestRun, currentRun)
        } else {
            currentRun = 0
        }
    }
    let fence = String(repeating: "`", count: longestRun + 1)
    let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
    return fence + padding + content + padding + fence
}
