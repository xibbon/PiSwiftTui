import Foundation
import PiSwiftCodingAgent

public struct RenderDiffOptions: Sendable {
    public var filePath: String?

    public init(filePath: String? = nil) {
        self.filePath = filePath
    }
}

public func renderDiff(_ diffText: String, _ options: RenderDiffOptions = RenderDiffOptions()) -> String {
    _ = options
    let lines = diffText.components(separatedBy: "\n")
    var rendered: [String] = []
    var index = 0
    while index < lines.count {
        guard let line = parseDisplayDiffLine(lines[index]) else {
            rendered.append(theme.fg(.toolDiffContext, lines[index]))
            index += 1
            continue
        }
        if line.prefix == "-" {
            var removed: [DisplayDiffLine] = []
            var added: [DisplayDiffLine] = []
            while index < lines.count, let next = parseDisplayDiffLine(lines[index]), next.prefix == "-" {
                removed.append(next)
                index += 1
            }
            while index < lines.count, let next = parseDisplayDiffLine(lines[index]), next.prefix == "+" {
                added.append(next)
                index += 1
            }
            if removed.count == 1, added.count == 1 {
                let pair = renderDisplayWordDiff(replaceTabs(removed[0].content), replaceTabs(added[0].content))
                rendered.append(theme.fg(.toolDiffRemoved, "-\(removed[0].number) \(pair.removed)"))
                rendered.append(theme.fg(.toolDiffAdded, "+\(added[0].number) \(pair.added)"))
            } else {
                rendered += removed.map { theme.fg(.toolDiffRemoved, "-\($0.number) \(replaceTabs($0.content))") }
                rendered += added.map { theme.fg(.toolDiffAdded, "+\($0.number) \(replaceTabs($0.content))") }
            }
        } else {
            let color: ThemeColor = line.prefix == "+" ? .toolDiffAdded : .toolDiffContext
            rendered.append(theme.fg(color, "\(line.prefix == "+" ? "+" : " ")\(line.number) \(replaceTabs(line.content))"))
            index += 1
        }
    }
    return rendered.joined(separator: "\n")
}

private struct DisplayDiffLine {
    let prefix: String
    let number: String
    let content: String
}

private func parseDisplayDiffLine(_ line: String) -> DisplayDiffLine? {
    guard let match = line.firstMatch(of: /^([+\-\s])(\s*\d*)\s(.*)$/) else { return nil }
    return DisplayDiffLine(prefix: String(match.1), number: String(match.2), content: String(match.3))
}

/// Keep shared indentation outside the changed word spans.
private func renderDisplayWordDiff(_ old: String, _ new: String) -> (removed: String, added: String) {
    let indentation = String(zip(old, new).prefix { $0 == $1 && $0.isWhitespace }.map(\.0))
    func tokens(_ value: String) -> [String] {
        let source = String(value.dropFirst(indentation.count))
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+\s*|[^\p{L}\p{M}\p{N}_\s]\s*|\s+"#)
        let text = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
    }
    let before = tokens(old)
    let after = tokens(new)
    let changes = after.difference(from: before) { lhs, rhs in
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var removedOffsets: Set<Int> = []
    var addedOffsets: Set<Int> = []
    for change in changes {
        switch change {
        case .remove(let offset, _, _): removedOffsets.insert(offset)
        case .insert(let offset, _, _): addedOffsets.insert(offset)
        }
    }
    var removed = indentation
    var added = indentation
    var oldIndex = 0
    var newIndex = 0
    var firstRemoved = true
    var firstAdded = true
    func changed(_ value: String, first: inout Bool) -> String {
        let whitespace = first ? String(value.prefix(while: \.isWhitespace)) : ""
        first = false
        let content = String(value.dropFirst(whitespace.count))
        return whitespace + (content.isEmpty ? "" : theme.inverse(content))
    }
    while oldIndex < before.count || newIndex < after.count {
        var removedPart = ""
        while removedOffsets.contains(oldIndex) {
            removedPart += before[oldIndex]
            oldIndex += 1
        }
        if !removedPart.isEmpty { removed += changed(removedPart, first: &firstRemoved) }
        var addedPart = ""
        while addedOffsets.contains(newIndex) {
            addedPart += after[newIndex]
            newIndex += 1
        }
        if !addedPart.isEmpty { added += changed(addedPart, first: &firstAdded) }
        if oldIndex < before.count, newIndex < after.count {
            removed += before[oldIndex]
            added += after[newIndex]
            oldIndex += 1
            newIndex += 1
        }
    }
    return (removed, added)
}
