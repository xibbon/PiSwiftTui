import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

/// JSON.stringify formatting for tool headers.
func toolArgumentJSON(_ value: OrderedJSON, pretty: Bool = false, depth: Int = 0, preserveOrder: Bool = false) -> String {
    let indent = String(repeating: "  ", count: depth)
    let childIndent = indent + "  "
    switch value {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let source): return javascriptNumber(Double(source) ?? .nan)
    case .string(let value): return javascriptJSONString(value)
    case .array(let values):
        let items = values.map { toolArgumentJSON($0, pretty: pretty, depth: depth + 1, preserveOrder: preserveOrder) }
        if items.isEmpty { return "[]" }
        return pretty ? "[\n" + items.map { childIndent + $0 }.joined(separator: ",\n") + "\n" + indent + "]" : "[" + items.joined(separator: ",") + "]"
    case .object(let sourcePairs):
        let pairs = preserveOrder ? sourcePairs : javascriptObjectEntries(sourcePairs)
        let items = pairs.map { javascriptJSONString($0.0) + (pretty ? ": " : ":") + toolArgumentJSON($0.1, pretty: pretty, depth: depth + 1, preserveOrder: preserveOrder) }
        if items.isEmpty { return "{}" }
        return pretty ? "{\n" + items.map { childIndent + $0 }.joined(separator: ",\n") + "\n" + indent + "}" : "{" + items.joined(separator: ",") + "}"
    }
}

private func javascriptObjectEntries(_ pairs: [(String, OrderedJSON)]) -> [(String, OrderedJSON)] {
    func index(_ key: String) -> UInt32? {
        guard let value = UInt32(key), value < UInt32.max, String(value) == key else { return nil }
        return value
    }
    return pairs.filter { index($0.0) != nil }.sorted { index($0.0)! < index($1.0)! }
        + pairs.filter { index($0.0) == nil }
}

private func javascriptJSONString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: result += "\\\""
        case 0x5c: result += "\\\\"
        case 8: result += "\\b"
        case 9: result += "\\t"
        case 10: result += "\\n"
        case 12: result += "\\f"
        case 13: result += "\\r"
        case 0...31: result += String(format: "\\u%04x", scalar.value)
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

/// Swift supplies shortest decimal digits. Apply ECMAScript's fixed/exponent ranges.
func javascriptNumber(_ number: Double) -> String {
    guard number.isFinite else { return "null" }
    guard number != 0 else { return "0" }
    let negative = number < 0 ? "-" : ""
    let parts = String(abs(number)).lowercased().split(separator: "e")
    let mantissa = String(parts[0])
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let decimal = mantissa.firstIndex(of: ".")
    var point = (decimal.map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count) + exponent
    var digits = mantissa.replacingOccurrences(of: ".", with: "")
    while digits.first == "0" { digits.removeFirst(); point -= 1 }
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    if point > 0 && point <= 21 {
        if digits.count <= point { return negative + digits + String(repeating: "0", count: point - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return negative + digits[..<split] + "." + digits[split...]
    }
    if point <= 0 && point > -6 { return negative + "0." + String(repeating: "0", count: -point) + digits }
    let rest = digits.dropFirst()
    let exp = point - 1
    return negative + String(digits.prefix(1)) + (rest.isEmpty ? "" : "." + rest) + "e" + (exp >= 0 ? "+" : "") + String(exp)
}

func toolPreview(_ text: String, maxCharacters: Int) -> String {
    guard text.utf16.count > maxCharacters else { return text }
    return String(decoding: text.utf16.prefix(maxCharacters - 3), as: UTF16.self) + "..."
}

public func formatToolCallWithArgs(_ title: String, args: [String: AnyCodable], theme: Theme, expanded: Bool) -> String {
    let values = toolArgumentsToOrderedJSON(args)
    let entries = orderedToolArguments(args).compactMap { pair in
        values[pair.key].map { (pair.key, $0) }
    }
    return formatToolArgumentEntries(title, entries: entries, theme: theme, expanded: expanded, preserveOrder: true)
}

public func formatToolCallWithArgs(_ title: String, args: OrderedJSON?, theme: Theme, expanded: Bool) -> String {
    let header = theme.fg(.toolTitle, theme.bold(title))
    guard let args else { return header }
    if case .null = args { return header }
    let entries = args.objectEntries.map(javascriptObjectEntries) ?? [("args", args)]
    return formatToolArgumentEntries(title, entries: entries, theme: theme, expanded: expanded, preserveOrder: false)
}

private func formatToolArgumentEntries(_ title: String, entries: [(String, OrderedJSON)], theme: Theme, expanded: Bool, preserveOrder: Bool) -> String {
    let header = theme.fg(.toolTitle, theme.bold(title))
    guard !entries.isEmpty else { return header }
    if expanded {
        let lines = entries.map { key, value in
            let raw = value.stringValue ?? toolArgumentJSON(value, pretty: true, preserveOrder: preserveOrder)
            return "  \(key): " + normalizeDisplayText(replaceTabs(raw)).replacingOccurrences(of: "\n", with: "\n    ")
        }
        return header + "\n" + theme.fg(.muted, lines.joined(separator: "\n"))
    }
    let pairs = entries.map { $0.0 + "=" + toolArgumentJSON($0.1, preserveOrder: preserveOrder) }.joined(separator: " ")
    return header + " " + theme.fg(.muted, toolPreview(pairs, maxCharacters: 100))
}
