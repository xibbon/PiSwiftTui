import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
public func createLsRenderers() -> ToolRenderers {
    ToolRenderers(renderCall: { args, theme, context in
        var text = theme.fg(.toolTitle, theme.bold("ls")) + " " + renderToolPath(str(args["path"]), theme, context.cwd, emptyFallback: ".")
        if let limit = args["limit"] { text += theme.fg(.toolOutput, " (limit \(toolArgumentDisplay(limit)))") }
        return toolText(text, context: context)
    }, renderResult: { result, options, theme, context in
        toolText(formatSearchToolResult(result, options: options, theme: theme, showImages: context.showImages, lineLimit: 20, limitKey: "entryLimitReached", limitLabel: "entries"), context: context)
    })
}
