import MiniTui
import PiSwiftCodingAgent

@MainActor
public func createAllToolRenderers() -> [String: ToolRenderers] {
    ["read": createReadRenderers(), "bash": createShellRenderers(prompt: "$"), "edit": createEditRenderers(), "write": createWriteRenderers(), "grep": createGrepRenderers(), "find": createFindRenderers(), "ls": createLsRenderers()]
}

/// A custom definition replaces each renderer slot independently.
@MainActor
public func withBuiltInRenderers(_ toolName: String, _ definition: CustomTool?, sourceInfo: SourceInfo? = nil) -> ToolRenderers? {
    let builtIn = builtInToolRenderers(toolName, definition, sourceInfo: sourceInfo)
    guard let definition else { return builtIn }
    return applyingRendererSlots(CustomToolRenderers(tool: definition), to: builtIn)
}

@MainActor
private func builtInToolRenderers(_ toolName: String, _ definition: CustomTool?, sourceInfo: SourceInfo?) -> ToolRenderers? {
    let builtIn: ToolRenderers?
    if toolName == "codemode", sourceInfo?.path == "builtin:codemode" {
        builtIn = createCodemodeRenderers()
    } else if sourceInfo?.path == "builtin:mcp", let namespace = definition?.namespace, namespace.name.hasPrefix("mcp__") {
        builtIn = createMcpRenderers(label: definition?.label ?? toolName)
    } else {
        builtIn = createAllToolRenderers()[toolName]
    }
    return builtIn
}

@MainActor
private func applyingRendererSlots(_ value: CustomToolRenderers, to builtIn: ToolRenderers?) -> ToolRenderers {
    var merged = builtIn ?? ToolRenderers()
    if let shell = value.renderShell { merged.renderShell = shell }
    if let call = value.renderCall {
        merged.renderCall = { args, theme, _ in
            try call(args, theme) as? Component ?? Text("", paddingX: 0, paddingY: 0)
        }
    }
    if let result = value.renderResult {
        merged.renderResult = { value, options, theme, context in
            let options = RenderResultOptions(expanded: options.expanded, isPartial: options.isPartial, durationMs: context.durationMs, outputPad: context.outputPad)
            return try result(value, options, theme) as? Component ?? Text("", paddingX: 0, paddingY: 0)
        }
    }
    return merged
}

/// Use the library resolver chain and draw host renderer families on the main actor.
@MainActor
func resolvedToolRenderers(_ name: String, session: AgentSession,
                           fallback: CustomTool? = nil) -> ToolRenderers? {
    let definition = registeredToolDefinition(name, session: session, fallback: fallback)
    let builtIn = builtInToolRenderers(name, definition,
        sourceInfo: session.hookRunner?.getToolSourceInfo(name))
    let base: () -> CustomToolRenderers? = {
        if let definition { return CustomToolRenderers(tool: definition) }
        // Keep host built-ins in the chain even when the library has no tool definition.
        return builtIn == nil ? nil : CustomToolRenderers()
    }
    let value: CustomToolRenderers?
    if let runner = session.hookRunner {
        value = runner.resolveToolRenderers(name, base: base)
    } else {
        value = base()
    }
    guard let value else { return nil }
    let family: ToolRenderers?
    switch value.builtIn {
    case .mcp(let label): family = createMcpRenderers(label: label)
    case nil: family = builtIn
    }
    return applyingRendererSlots(value, to: family)
}
