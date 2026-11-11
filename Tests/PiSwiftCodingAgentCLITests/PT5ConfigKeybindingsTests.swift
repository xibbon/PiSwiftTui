import Foundation
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI
import PiSwiftCodingAgentTui

// v1.5.2 PT5: config-selector-keybindings.test.ts:51, "uses the user's keybindings.json".
@MainActor @Suite(.serialized) struct PT5ConfigKeybindingsTests {
    @Test func usesTheUsersKeybindingsJson() async throws {
        let agentDir = FileManager.default.temporaryDirectory.appendingPathComponent("pt5-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDir) }
        try Data(#"{"tui.select.up":["up","ctrl+p"],"tui.select.down":["down","ctrl+n"]}"#.utf8)
            .write(to: agentDir.appendingPathComponent("keybindings.json"))

        var started = false
        await selectConfig(resolvedPaths: ResolvedPaths(), settingsManager: SettingsManager.inMemory(),
                           cwd: agentDir.path, agentDir: agentDir.path, projectTrusted: false,
                           prepareTheme: { _ in }, installKeybindings: { manager in
            let effective = manager.getEffectiveConfig()
            #expect(effective["tui.select.up"]?.contains("ctrl+p") == true)
            #expect(effective["tui.select.down"]?.contains("ctrl+n") == true)
        }, startUI: { _, _, _, close in
            started = true
            close()
        })
        #expect(started)
    }
}
