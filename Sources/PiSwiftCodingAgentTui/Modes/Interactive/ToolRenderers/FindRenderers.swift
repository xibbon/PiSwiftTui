import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
public func createFindRenderers() -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        let pattern = str(args["pattern"])
        let rawPath = str(args["path"])
        let path = rawPath.map { shortenPath($0.isEmpty ? "." : $0) }
        var text = theme.fg(.toolTitle, theme.bold("find")) + " " + (pattern.map { theme.fg(.accent, $0) } ?? invalidArgText(theme)) + theme.fg(.toolOutput, " in \(path ?? invalidArgText(theme))")
        if let limit = args["limit"] { text += theme.fg(.toolOutput, " (limit \(toolArgumentDisplay(limit)))") }
        return toolText(text, context: context)
    }, renderResult: { result, options, theme, context in
        toolText(formatSearchToolResult(result, options: options, theme: theme, showImages: context.showImages, lineLimit: 20, limitKey: "resultLimitReached", limitLabel: "results"), context: context)
    })
}
