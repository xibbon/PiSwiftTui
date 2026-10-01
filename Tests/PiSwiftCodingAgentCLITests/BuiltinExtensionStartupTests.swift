import Foundation
import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

@Suite struct BuiltinExtensionStartupTests {
    private let path = "builtin:tool-search"

    @Test func commandLineAcceptsExplicitBuiltin() throws {
        let options = try CLIOptions.parse(["--no-extensions", "-e", "builtin:tool-search"])
        #expect(options.noExtensions)
        #expect(options.extensions == ["builtin:tool-search"])
    }

    @Test func builtInSelectionFollowsSettingsAndFlags() {
        // C5b added builtin:codemode before tool-search and C4b added builtin:mcp after it
        // (upstream order without the deferred llama.cpp).
        let builtin = builtInExtensions
        #expect(selectStartupInlineExtensions(builtin, disabledPaths: [], explicitPaths: [],
            noExtensions: false).map(\.name) == ["codemode", "tool-search", "mcp"])
        #expect(selectStartupInlineExtensions(builtin, disabledPaths: ["-" + path], explicitPaths: [],
            noExtensions: false).map(\.name) == ["codemode", "mcp"])
        #expect(selectStartupInlineExtensions(builtin, disabledPaths: [], explicitPaths: [],
            noExtensions: true).isEmpty)
        #expect(selectStartupInlineExtensions(builtin, disabledPaths: ["-" + path], explicitPaths: [path],
            noExtensions: true).map(\.name) == ["tool-search"])
    }

    @Test func toolSearchIsRegisteredButInitiallyInactive() {
        let result = ExtensionLoader.load(createToolSearchExtension(), cwd: FileManager.default.currentDirectoryPath,
            eventBus: createEventBus())
        let hook = try? #require(result.hook)
        #expect(hook?.path == path)
        #expect(hook?.hidden == true)
        let tool = hook?.tools[TOOL_SEARCH_TOOL_NAME]
        #expect(tool != nil)
        #expect(tool?.exposure == .modelOnly)
        #expect(tool?.defaultActive == false)
        #expect(!activatesStartupTool(tool))
        var deferred = createToolSearchToolDefinition()
        deferred.exposure = .deferred
        deferred.defaultActive = true
        #expect(!activatesStartupTool(deferred))
        deferred.exposure = .codemode
        #expect(!activatesStartupTool(deferred))
    }

    @Test func anotherProviderReplacesTheBuiltin() throws {
        let replacement = InlineExtension(name: "replacement") { api in
            _ = api.registerTool(createToolSearchToolDefinition())
        }
        let bus = createEventBus()
        let other = try #require(ExtensionLoader.load(replacement, cwd: FileManager.default.currentDirectoryPath,
            eventBus: bus).hook)
        let builtin = try #require(ExtensionLoader.load(createToolSearchExtension(),
            cwd: FileManager.default.currentDirectoryPath, eventBus: bus).hook)
        let result = omitReplacedExtensions([other, builtin])
        #expect(result.hooks.map(\.path) == [other.path])
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("tool_search"))
    }
}
