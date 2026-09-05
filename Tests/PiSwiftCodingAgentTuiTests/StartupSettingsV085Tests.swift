import Foundation
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@Suite struct StartupSettingsV085Tests {
    @Test func fullscreenSettingsPersistAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager.create(directory.path, directory.path)
        settings.setFullscreenExitOutput(.resumeHint)
        settings.setFullscreenCopyOnSelect(false)
        await settings.flush()
        let reloaded = SettingsManager.create(directory.path, directory.path)
        #expect(reloaded.getFullscreenExitOutput() == .resumeHint)
        #expect(!reloaded.getFullscreenCopyOnSelect())
    }

    @Test func shrinkSettingUsesProjectThenGlobalThenEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("project")
        let global = directory.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(CONFIG_DIR_NAME), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(getClearOnShrink(cwd: project.path, agentDir: global.path, environment: [:]) == false)
        #expect(getClearOnShrink(cwd: project.path, agentDir: global.path, environment: ["PI_CLEAR_ON_SHRINK": "1"]))
        try #"{"terminal":{"clearOnShrink":false}}"#.write(to: global.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(!getClearOnShrink(cwd: project.path, agentDir: global.path, environment: ["PI_CLEAR_ON_SHRINK": "1"]))
        try #"{"terminal":{"clearOnShrink":true}}"#.write(to: project.appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(getClearOnShrink(cwd: project.path, agentDir: global.path, environment: [:]))
        #expect(!getClearOnShrink(cwd: project.path, agentDir: global.path, loadProjectSettings: false, environment: [:]))
    }
}
