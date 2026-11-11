import Foundation

struct MermaidFlowPresentation {
    var source: String
    var styles: [String: MermaidAuthoredStyle]
    var links: [String: String]
    var edgeStyles: [Int: MermaidAuthoredStyle]
    var warnings: [String]
    var orphanLabels: [String]
}

struct MermaidAuthoredStyle: Sendable {
    var fill: MermaidRGB?
    var stroke: MermaidRGB?
    var color: MermaidRGB?
    var bold = false

    init(_ declaration: String) {
        for property in splitMermaidClassProperties(declaration) {
            let parts = property.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "fill": if let parsed = parseMermaidClassColor(parts[1]) { fill = parsed }
            case "stroke": if let parsed = parseMermaidClassColor(parts[1]) { stroke = parsed }
            case "color": if let parsed = parseMermaidClassColor(parts[1]) { color = parsed }
            case "font-weight": bold = parts[1] == "bold" || parts[1] == "bolder"
            default: break
            }
        }
    }

    func apply(_ text: String, border: Bool, fallback: String) -> String? {
        guard fill != nil || stroke != nil || color != nil || bold else { return nil }
        var codes: [String] = []
        let foreground = (border ? (stroke ?? color) : color) ?? fill?.contrastingForeground
        if let foreground {
            codes.append(foreground.foregroundSGR)
        }
        if let fill {
            codes.append(fill.backgroundSGR)
        }
        if codes.isEmpty {
            let color = fallback.hasPrefix("\u{1B}[") && fallback.hasSuffix("m")
                ? String(fallback.dropFirst(2).dropLast()) : fallback
            codes.append(color)
        }
        if bold { codes.insert("1", at: 0) }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
    }
}

func mermaidFlowPresentation(_ source: String) -> MermaidFlowPresentation {
    var lines: [String] = []
    var definitions: [String: MermaidAuthoredStyle] = [:]
    var assigned: [String: String] = [:]
    var links: [String: String] = [:]
    let edgeStyles: [Int: MermaidAuthoredStyle] = [:]
    var warnings: [String] = []
    var orphanLabels: [String] = []
    for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        switch fields.first {
        case "classDef" where fields.count >= 3:
            definitions[fields[1]] = MermaidAuthoredStyle(fields.dropFirst(2).joined(separator: " "))
        case "class" where fields.count >= 3:
            for id in fields[1].split(separator: ",") { assigned[String(id)] = fields[2] }
        // lovely-mermaid 0.3.3 does not paint `style` or `linkStyle` declarations.
        case "style", "linkStyle":
            break
        case "click" where fields.count >= 3:
            let urlIndex = fields[2].lowercased() == "href" ? 3 : 2
            if fields.indices.contains(urlIndex), fields[urlIndex].hasPrefix("\"") {
                let url = fields[urlIndex].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if url.hasPrefix("https://") || url.hasPrefix("http://") { links[fields[1]] = url }
            }
        default:
            if fields.count == 2, fields[1] == "!" || fields[1] == "?" {
                warnings.append("dropped, expected a link: \"\(fields[1])\"")
                orphanLabels.append(fields[0])
                continue
            }
            if let range = trimmed.range(of: ":::"),
               let id = trimmed[..<range.lowerBound].split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).first {
                let className = trimmed[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                assigned[String(id)] = String(className)
            }
            if let range = line.range(of: ":::") {
                let end = line[range.upperBound...].firstIndex { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" } ?? line.endIndex
                lines.append(String(line[..<range.lowerBound]) + line[end...])
            } else {
                lines.append(line)
            }
        }
    }
    var styles: [String: MermaidAuthoredStyle] = [:]
    for (id, className) in assigned { styles[id] = definitions[className] }
    return MermaidFlowPresentation(source: lines.joined(separator: "\n"), styles: styles, links: links,
                                   edgeStyles: edgeStyles, warnings: warnings, orphanLabels: orphanLabels)
}
