import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private struct WriteHighlightCache {
    var rawPath: String?
    var lang: String
    var rawContent: String
    var normalizedLines: [String]
    var highlightedLines: [String]
}

private final class WriteCallRenderComponent: Text {
    var cache: WriteHighlightCache?
    init() { super.init("", paddingX: 0, paddingY: 0) }
}

private func rebuildWriteHighlightCache(_ rawPath: String?, content: String) -> WriteHighlightCache? {
    guard let rawPath, !rawPath.isEmpty, let lang = getLanguageFromPath(rawPath) else { return nil }
    let normalized = replaceTabs(normalizeDisplayText(content))
    return WriteHighlightCache(rawPath: rawPath, lang: lang, rawContent: content, normalizedLines: normalized.components(separatedBy: "\n"), highlightedLines: highlightCode(normalized, lang: lang))
}

private func highlightWriteLine(_ line: String, lang: String) -> String {
    highlightCode(line, lang: lang).first ?? ""
}

private func updateWriteHighlightCache(_ old: WriteHighlightCache?, rawPath: String?, content: String) -> WriteHighlightCache? {
    guard let rawPath, !rawPath.isEmpty, let lang = getLanguageFromPath(rawPath) else { return nil }
    guard var cache = old, cache.lang == lang, cache.rawPath == rawPath, content.utf8.starts(with: cache.rawContent.utf8) else {
        return rebuildWriteHighlightCache(rawPath, content: content)
    }
    if content == cache.rawContent { return cache }
    let delta = replaceTabs(normalizeDisplayText(String(content.unicodeScalars.dropFirst(cache.rawContent.unicodeScalars.count))))
    cache.rawContent = content
    if cache.normalizedLines.isEmpty {
        cache.normalizedLines.append("")
        cache.highlightedLines.append("")
    }
    let segments = delta.components(separatedBy: "\n")
    let last = cache.normalizedLines.count - 1
    cache.normalizedLines[last] += segments[0]
    cache.highlightedLines[last] = highlightWriteLine(cache.normalizedLines[last], lang: lang)
    for segment in segments.dropFirst() {
        cache.normalizedLines.append(segment)
        cache.highlightedLines.append(highlightWriteLine(segment, lang: lang))
    }
    let prefixCount = min(50, cache.normalizedLines.count)
    let prefix = highlightCode(cache.normalizedLines.prefix(prefixCount).joined(separator: "\n"), lang: lang)
    for index in 0..<prefixCount {
        cache.highlightedLines[index] = index < prefix.count ? prefix[index] : highlightWriteLine(cache.normalizedLines[index], lang: lang)
    }
    return cache
}

@MainActor
public func createWriteRenderers() -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        let rawPath = str(toolPathArgument(args))
        let content = str(args["content"])
        let component = context.lastComponent as? WriteCallRenderComponent ?? WriteCallRenderComponent()
        if let content {
            component.cache = context.argsComplete ? rebuildWriteHighlightCache(rawPath, content: content) : updateWriteHighlightCache(component.cache, rawPath: rawPath, content: content)
        } else {
            component.cache = nil
        }
        var text = theme.fg(.toolTitle, theme.bold("write")) + " " + renderToolPath(rawPath, theme, context.cwd)
        if let content {
            if !content.isEmpty {
                let lang = rawPath.flatMap { $0.isEmpty ? nil : getLanguageFromPath($0) }
                let rendered: [String]
                if let lang {
                    rendered = component.cache?.highlightedLines ?? highlightCode(replaceTabs(normalizeDisplayText(content)), lang: lang)
                } else {
                    rendered = normalizeDisplayText(content).components(separatedBy: "\n")
                }
                let lines = trimToolTrailingEmptyLines(rendered)
                let visible = context.expanded ? lines : Array(lines.prefix(10))
                text += "\n\n" + visible.map { lang != nil ? $0 : theme.fg(.toolOutput, replaceTabs($0)) }.joined(separator: "\n")
                if visible.count < lines.count {
                    text += theme.fg(.muted, "\n... (\(lines.count - visible.count) more lines, \(lines.count) total,") + " " + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
                }
            }
        } else {
            text += "\n\n" + theme.fg(.error, "[invalid content arg - expected string]")
        }
        component.setText(text)
        return component
    }, renderResult: { result, _, theme, context in
        let output = result.content.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.text
        }.joined(separator: "\n")
        if !context.isError || output.isEmpty {
            let component = context.lastComponent as? Container ?? Container()
            component.clear()
            return component
        }
        return toolText("\n" + theme.fg(.error, output), context: context)
    })
}
