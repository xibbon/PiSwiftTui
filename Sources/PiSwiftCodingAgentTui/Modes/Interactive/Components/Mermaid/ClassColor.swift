import Foundation

struct MermaidRGB: Sendable, Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var foregroundSGR: String { "38;2;\(red);\(green);\(blue)" }
    var backgroundSGR: String { "48;2;\(red);\(green);\(blue)" }

    var contrastingForeground: MermaidRGB {
        let yiq = (red * 299 + green * 587 + blue * 114) / 1000
        let value = yiq >= 128 ? 0 : 255
        return MermaidRGB(red: value, green: value, blue: value)
    }
}

/// Match lovely-mermaid 0.3.3 class-style.ts normalizeColor.
func parseMermaidClassColor(_ raw: String) -> MermaidRGB? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hex: String
    if value.hasPrefix("#") {
        hex = String(value.dropFirst())
    } else if let named = mermaidNamedColor(value) {
        hex = String(named.dropFirst())
    } else {
        // The package matches the first three decimal channels of rgb()/rgba().
        let pattern = #"^rgba?\(\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+"#
        guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
        let numbers = value[range].split(whereSeparator: { !$0.isNumber })
        guard numbers.count == 3 else { return nil }
        let channels = numbers.map { digits in
            digits.reduce(0) { current, digit in
                min(255, current * 10 + (digit.wholeNumberValue ?? 0))
            }
        }
        return MermaidRGB(red: channels[0], green: channels[1], blue: channels[2])
    }
    if hex.count == 3, let number = Int(hex, radix: 16) {
        return MermaidRGB(red: ((number >> 8) & 15) * 17,
                          green: ((number >> 4) & 15) * 17, blue: (number & 15) * 17)
    }
    if hex.count == 6, let number = Int(hex, radix: 16) {
        return MermaidRGB(red: (number >> 16) & 255,
                          green: (number >> 8) & 255, blue: number & 255)
    }
    return nil
}

/// Match statements.ts splitTop: commas inside parentheses or quotes stay in a value.
func splitMermaidClassProperties(_ declaration: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inQuotes = false
    var depth = 0
    for character in declaration {
        if character == "\"" { inQuotes.toggle() }
        else if !inQuotes && character == "(" { depth += 1 }
        else if !inQuotes && character == ")" && depth > 0 { depth -= 1 }
        if character == "," && !inQuotes && depth == 0 {
            if !current.isEmpty { parts.append(current) }
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { parts.append(current) }
    return parts
}
