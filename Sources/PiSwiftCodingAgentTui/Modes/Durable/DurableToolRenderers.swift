import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
func createDurableToolRenderers() -> [String: ToolRenderers] {
    var renderers = createAllToolRenderers()
    renderers["codemode"] = createDurableCodemodeRenderers()
    return renderers
}

/// Use the shared script view and show the saved durable call IDs and output path.
@MainActor
func createDurableCodemodeRenderers() -> ToolRenderers {
    let shared = createCodemodeRenderers()
    return ToolRenderers(renderCall: shared.renderCall, renderResult: { result, options, theme, context in
        var details = toolDetails(result)
        if let calls = details["calls"] as? [[String: Any]] {
            details["calls"] = calls.map { call in
                var display = call
                if let id = call["id"] as? Int {
                    display["name"] = "#\(id) " + (call["name"] as? String ?? "")
                }
                return display
            }
        }
        // Keep the path visible with empty output and in the expanded view.
        let path = details.removeValue(forKey: "fullOutputPath") as? String
        let output = AgentToolResult(content: result.content, details: AnyCodable(details))
        let component = try shared.renderResult?(output, options, theme, context) ?? Container()
        if !options.isPartial, let path, !path.isEmpty, let container = component as? Container {
            container.addChild(Text(theme.fg(.muted, "Full output: \(path)"), paddingX: 0, paddingY: 0))
        }
        return component
    })
}
