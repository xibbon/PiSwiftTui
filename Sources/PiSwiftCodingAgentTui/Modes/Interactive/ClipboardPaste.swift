import Foundation

func quoteIfNeeded(_ value: String) -> String {
    if !value.isEmpty, value.range(of: #"[^a-zA-Z0-9_\-./~:@]"#, options: .regularExpression) == nil { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum ClipboardPasteError: Error, LocalizedError {
    case controlCharacters
    case read(String)
    var errorDescription: String? {
        switch self {
        case .controlCharacters: "Clipboard file path contains control characters"
        case .read(let message): message
        }
    }
}

func clipboardFileInsertion(_ paths: [String], bashMode: Bool, text: String, cursor: (line: Int, col: Int)?) throws -> String {
    if paths.contains(where: { $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) {
        throw ClipboardPasteError.controlCharacters
    }
    let value = bashMode ? paths.map(quoteIfNeeded).joined(separator: " ") : paths.joined(separator: "\n")
    let lines = text.components(separatedBy: "\n")
    let line = cursor.flatMap { lines.indices.contains($0.line) ? lines[$0.line] : nil } ?? ""
    // MiniTui reports cursor columns in Swift Characters.
    let chars = Array(line)
    let col = cursor?.col ?? 0
    func needsSpace(_ index: Int) -> Bool {
        guard chars.indices.contains(index) else { return false }
        return !chars[index].isWhitespace && chars[index] != "\u{FEFF}"
    }
    return (col > 0 && needsSpace(col - 1) ? " " : "") + value + (needsSpace(col) ? " " : "")
}
