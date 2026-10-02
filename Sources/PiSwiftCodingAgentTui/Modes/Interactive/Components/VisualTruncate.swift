import Foundation
import MiniTui
import PiSwiftCodingAgent

public struct VisualTruncateResult: Sendable {
    public var visualLines: [String]
    public var skippedCount: Int

    public init(visualLines: [String], skippedCount: Int) {
        self.visualLines = visualLines
        self.skippedCount = skippedCount
    }
}

public enum VisualLineKeep: Equatable, Sendable {
    case start
    case end
}

@MainActor
public func truncateToVisualLines(
    _ text: String,
    maxVisualLines: Int,
    width: Int,
    paddingX: Int = 0,
    keep: VisualLineKeep = .end
) -> VisualTruncateResult {
    guard !text.isEmpty else {
        return VisualTruncateResult(visualLines: [], skippedCount: 0)
    }

    let tempText = Text(text, paddingX: paddingX, paddingY: 0)
    let allLines = tempText.render(width: width)

    if allLines.count <= maxVisualLines {
        return VisualTruncateResult(visualLines: allLines, skippedCount: 0)
    }

    let truncated = keep == .start ? Array(allLines.prefix(maxVisualLines)) : Array(allLines.suffix(maxVisualLines))
    let skipped = allLines.count - maxVisualLines
    return VisualTruncateResult(visualLines: truncated, skippedCount: skipped)
}

/// A collapsed preview that limits wrapped lines and caches the last rendered width.
@MainActor
public final class VisualLinePreview: Component {
    private let text: String
    private let maxVisualLines: Int
    private let keep: VisualLineKeep
    private let formatHint: (Int) -> String
    private var cachedWidth: Int?
    private var cachedLines: [String]?

    public init(text: String, maxVisualLines: Int, keep: VisualLineKeep, formatHint: @escaping (Int) -> String) {
        self.text = text
        self.maxVisualLines = maxVisualLines
        self.keep = keep
        self.formatHint = formatHint
    }

    public func render(width: Int) -> [String] {
        if cachedLines == nil || cachedWidth != width {
            let preview = truncateToVisualLines(text, maxVisualLines: maxVisualLines, width: width, keep: keep)
            if preview.skippedCount > 0 {
                let hint = truncateToWidth(formatHint(preview.skippedCount), maxWidth: width, ellipsis: "...")
                cachedLines = keep == .start ? preview.visualLines + [hint] : [hint] + preview.visualLines
            } else {
                cachedLines = preview.visualLines
            }
            cachedWidth = width
        }
        return cachedLines ?? []
    }

    public func invalidate() {
        cachedWidth = nil
        cachedLines = nil
    }
}
