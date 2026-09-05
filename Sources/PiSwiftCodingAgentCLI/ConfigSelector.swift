import Darwin
import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

public func selectConfig(
    resolvedPaths: ResolvedPaths,
    settingsManager: SettingsManager,
    cwd: String,
    agentDir: String,
    initialProjectMode: Bool = false,
    projectTrusted: Bool = true
) async {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            initTheme(settingsManager.getTheme(), enableWatcher: true)
            applyStartupTerminalSettings(settingsManager)
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: cwd, agentDir: agentDir, loadProjectSettings: projectTrusted))
            var resolved = false

            let selector = ConfigSelectorComponent(
                resolvedPaths: resolvedPaths,
                settingsManager: settingsManager,
                cwd: cwd,
                agentDir: agentDir,
                onClose: {
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    stopThemeWatcher()
                    continuation.resume()
                },
                onExit: {
                    ui.stop()
                    stopThemeWatcher()
                    Darwin.exit(0)
                },
                requestRender: {
                    ui.requestRender()
                },
                initialProjectMode: initialProjectMode
            )

            ui.addChild(selector)
            ui.setFocus(selector.getResourceList())
            ui.start()
        }
    }
}
