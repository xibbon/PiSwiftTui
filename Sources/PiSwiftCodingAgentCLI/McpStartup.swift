import Foundation
import PiSwiftCodingAgent

/// Supply the interactive host before the built-in extension is loaded.
func startupBuiltinExtensions(agentDir: URL, mcpUi: (any McpUi)?) -> [InlineExtension] {
    guard let mcpUi else { return builtInExtensions }
    return builtInExtensions.map { item in
        item.name == "mcp"
            ? createMcpExtension(options: McpExtensionOptions(agentDir: agentDir, ui: mcpUi))
            : item
    }
}
