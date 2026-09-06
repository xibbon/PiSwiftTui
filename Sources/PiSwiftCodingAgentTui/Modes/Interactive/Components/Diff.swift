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
    let lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var rendered: [String] = []

    for line in lines {
        let trimmed = replaceTabs(line)
        if trimmed.hasPrefix("-") {
            rendered.append(theme.fg(.toolDiffRemoved, trimmed))
        } else if trimmed.hasPrefix("+") {
            rendered.append(theme.fg(.toolDiffAdded, trimmed))
        } else {
            rendered.append(theme.fg(.toolDiffContext, trimmed))
        }
    }

    return rendered.joined(separator: "\n")
}
