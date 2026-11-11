import Foundation
import MiniTui
import PiSwiftCodingAgent

struct MermaidPieResult {
    let lines: [String]
    let warnings: [String]
}

private struct PieSlice {
    let label: String
    let value: Double
    let valueText: String
}

/// A terminal pie chart is a labelled list of 20-column bars, as in lovely-mermaid 0.3.3.
func renderMermaidPie(_ source: String, theme: Theme?) -> MermaidPieResult? {
    let statements = source.split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    guard let header = statements.first, header.lowercased().hasPrefix("pie"),
          header.count == 3 || header.dropFirst(3).first?.isWhitespace == true else { return nil }
    let words = header.split(whereSeparator: \.isWhitespace).map(String.init)
    let showData = words.contains { $0.lowercased() == "showdata" }
    var title: String?
    if let index = words.firstIndex(where: { $0.lowercased() == "title" }) {
        let rest = words.dropFirst(index + 1).joined(separator: " ")
        title = rest.isEmpty ? nil : rest
    }
    var slices: [PieSlice] = []
    var warnings: [String] = []
    for statement in statements.dropFirst() {
        if statement.lowercased().hasPrefix("title ") {
            let rest = statement.dropFirst(5).trimmingCharacters(in: .whitespaces)
            title = rest.isEmpty ? nil : rest
            continue
        }
        guard let colon = statement.firstIndex(of: ":") else {
            warnings.append("dropped, unreadable statement: \"\(statement)\"")
            continue
        }
        var label = statement[..<colon].trimmingCharacters(in: .whitespaces)
        if label.count >= 2, (label.hasPrefix("\"") && label.hasSuffix("\"")) ||
            (label.hasPrefix("'") && label.hasSuffix("'")) {
            label = String(label.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if visibleWidth(label) > 24 {
            var fitted = ""
            for character in label {
                if visibleWidth(fitted + String(character)) > 23 { break }
                fitted.append(character)
            }
            label = fitted + "…"
        }
        let valueText = statement[statement.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, let value = Double(valueText), value.isFinite, value >= 0 else {
            warnings.append("dropped, unreadable statement: \"\(statement)\"")
            continue
        }
        if slices.count == 128 {
            warnings.append("diagram truncated: slice cap (128) reached")
            break
        }
        slices.append(PieSlice(label: label, value: value, valueText: valueText))
    }
    guard !slices.isEmpty else { return nil }
    let labelWidth = slices.map { visibleWidth($0.label) }.max() ?? 0
    let total = slices.reduce(0) { $0 + $1.value }
    let suffixes = slices.map { slice -> String in
        let share = total == 0 || !total.isFinite ? 0 : slice.value / total
        let percent = Int((share * 100).rounded(.toNearestOrAwayFromZero))
        let percentText = String(percent) + "%"
        return String(repeating: " ", count: max(0, 4 - percentText.count)) + percentText
            + (showData ? "  (\(slice.valueText))" : "")
    }
    let width = labelWidth + 2 + 20 + 1 + (suffixes.map(visibleWidth).max() ?? 0)
    var lines: [String] = []
    if let title {
        let indent = max(0, (width - visibleWidth(title)) / 2)
        lines.append(String(repeating: " ", count: indent) + (theme?.fg(.accent, title) ?? title))
    }
    for (index, slice) in slices.enumerated() {
        let share = total == 0 || !total.isFinite ? 0 : slice.value / total
        let eighths = min(160, max(0, Int((share * 160).rounded(.toNearestOrAwayFromZero))))
        let eighthBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var bar = String(repeating: "█", count: eighths / 8) + eighthBlocks[eighths % 8]
        if bar.isEmpty && slice.value > 0 { bar = "▏" }
        let track = String(repeating: "░", count: max(0, 20 - visibleWidth(bar)))
        let label = theme?.fg(.text, slice.label) ?? slice.label
        let coloredBar = theme?.fg(.accent, bar) ?? bar
        let coloredTrack = theme?.fg(.borderMuted, track) ?? track
        let suffix = theme?.fg(.text, suffixes[index]) ?? suffixes[index]
        lines.append(label + String(repeating: " ", count: labelWidth - visibleWidth(slice.label) + 2)
            + coloredBar + coloredTrack + " " + suffix)
    }
    return MermaidPieResult(lines: lines, warnings: warnings)
}
