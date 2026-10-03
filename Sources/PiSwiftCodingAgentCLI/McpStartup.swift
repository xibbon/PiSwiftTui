import Foundation
import PiSwiftCodingAgent

// W2: the Swift client's own Client ID Metadata Document on GitHub Pages; nil until it is published. With nil, oauth.clientRegistration "cimd" fails with a clear error.
let piSwiftClientMetadataDocumentURL: URL? = nil

/// Supply the interactive host before the built-in extension is loaded.
func startupBuiltinExtensions(agentDir: URL, mcpUi: (any McpUi)?) -> [InlineExtension] {
    return builtInExtensions.map { item in
        item.name == "mcp"
            ? createMcpExtension(options: McpExtensionOptions(agentDir: agentDir, ui: mcpUi,
                clientMetadataDocumentURL: piSwiftClientMetadataDocumentURL))
            : item
    }
}
