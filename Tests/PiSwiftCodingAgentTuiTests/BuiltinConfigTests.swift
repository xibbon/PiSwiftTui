import Foundation
import XCTest
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

final class BuiltinConfigTests: XCTestCase {
    func testBuiltinIsHiddenFromStartupExtensions() {
        XCTAssertEqual(visibleStartupExtensionPaths(["builtin:tool-search", "/tmp/example.swift"]),
            ["/tmp/example.swift"])
    }

    @MainActor func testBuiltinRowTogglesGlobalAndProjectSettings() {
        let settings = SettingsManager.inMemory()
        let path = "builtin:tool-search"
        let selector = ConfigSelectorComponent(
            resolvedPaths: ResolvedPaths(extensions: [ResolvedResource(path: path, enabled: true,
                metadata: PathMetadata(source: "builtin", scope: "user", origin: "top-level"))]),
            settingsManager: settings, cwd: FileManager.default.currentDirectoryPath,
            agentDir: FileManager.default.temporaryDirectory.path,
            onClose: {}, onExit: {}, requestRender: {}
        )
        let list = selector.getResourceList()
        XCTAssertTrue(list.render(width: 80).joined(separator: "\n").contains("Built-in extensions"))
        XCTAssertTrue(list.render(width: 80).joined(separator: "\n").contains("tool-search"))
        list.handleInput(" ")
        XCTAssertTrue((settings.getGlobalSettings().extensions ?? []).contains("-" + path),
            "global=\(settings.getGlobalSettings().extensions ?? []) view=\(list.render(width: 80))")
        list.handleInput("\t")
        XCTAssertTrue(list.render(width: 80).joined(separator: "\n").contains("tool-search"))
        list.handleInput(" ")
        XCTAssertTrue((settings.getProjectSettings().extensions ?? []).contains("+" + path),
            "project=\(settings.getProjectSettings().extensions ?? []) view=\(list.render(width: 80))")
        XCTAssertTrue(builtinExtensionSetting(path: path, global: settings.getGlobalSettings().extensions ?? [],
            project: settings.getProjectSettings().extensions ?? []).enabled)
        list.handleInput(" ")
        XCTAssertTrue((settings.getProjectSettings().extensions ?? []).contains("-" + path))
        list.handleInput(" ")
        XCTAssertFalse((settings.getProjectSettings().extensions ?? []).contains("-" + path))
        XCTAssertFalse((settings.getProjectSettings().extensions ?? []).contains("+" + path))
    }
}
