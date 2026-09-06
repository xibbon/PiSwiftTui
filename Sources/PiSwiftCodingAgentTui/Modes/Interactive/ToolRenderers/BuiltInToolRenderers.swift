import MiniTui
import PiSwiftCodingAgent

@MainActor
public func createAllToolRenderers() -> [String: ToolRenderers] {
    ["read": createReadRenderers(), "bash": createShellRenderers(prompt: "$"), "edit": createEditRenderers(), "write": createWriteRenderers(), "grep": createGrepRenderers(), "find": createFindRenderers(), "ls": createLsRenderers()]
}

/// A custom definition replaces each renderer slot independently.
@MainActor
public func withBuiltInRenderers(_ toolName: String, _ definition: CustomTool?) -> ToolRenderers? {
    let builtIn = createAllToolRenderers()[toolName]
    guard let definition else { return builtIn }
    var merged = builtIn ?? ToolRenderers()
    merged.renderShell = definition.renderShell
    if let call = definition.renderCall {
        merged.renderCall = { args, theme, _ in
            try call(args, theme) as? Component ?? Text("", paddingX: 0, paddingY: 0)
        }
    }
    if let result = definition.renderResult {
        merged.renderResult = { value, options, theme, _ in
            try result(value, options, theme) as? Component ?? Text("", paddingX: 0, paddingY: 0)
        }
    }
    return merged
}
