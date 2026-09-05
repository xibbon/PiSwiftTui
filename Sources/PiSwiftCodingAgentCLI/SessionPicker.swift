import Darwin
import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

public func selectSession(
    settingsManager: SettingsManager = SettingsManager.create(),
    projectTrusted: Bool = true,
    currentSessionsLoader: @escaping SessionsLoader,
    allSessionsLoader: @escaping SessionsLoader
) async -> String? {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            applyStartupTerminalSettings(settingsManager)
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: FileManager.default.currentDirectoryPath, agentDir: getAgentDir(), loadProjectSettings: projectTrusted))
            var resolved = false

            let selector = SessionSelectorComponent(
                currentSessionsLoader: currentSessionsLoader,
                allSessionsLoader: allSessionsLoader,
                onSelect: { path in
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    continuation.resume(returning: path)
                },
                onCancel: {
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    continuation.resume(returning: nil)
                },
                onExit: {
                    ui.stop()
                    Darwin.exit(0)
                },
                requestRender: {
                    ui.requestRender()
                }
            )

            ui.addChild(selector)
            ui.setFocus(selector.getSessionList())
            ui.start()
        }
    }
}
