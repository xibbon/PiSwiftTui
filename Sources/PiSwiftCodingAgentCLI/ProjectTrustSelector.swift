import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

public func selectProjectTrustOption(
    cwd: String,
    settingsManager: SettingsManager,
    includeSessionOnly: Bool = true
) async -> ProjectTrustOption? {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            initTheme(settingsManager.getTheme(), enableWatcher: true)
            applyStartupTerminalSettings(settingsManager)
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: cwd, agentDir: getAgentDir(), loadProjectSettings: false))
            var resolved = false
            let options = getProjectTrustOptions(cwd, includeSessionOnly: includeSessionOnly)

            let selector = ProjectTrustSelectorComponent(
                cwd: cwd,
                options: options,
                onSelect: { option in
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    stopThemeWatcher()
                    continuation.resume(returning: option)
                },
                onCancel: {
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    stopThemeWatcher()
                    continuation.resume(returning: nil)
                },
                savedDecision: startupSavedTrustDecision(cwd: cwd, settingsManager: settingsManager),
                projectTrusted: settingsManager.getProjectTrust(cwd)
            )

            ui.addChild(selector)
            ui.setFocus(selector)
            ui.start()
        }
    }
}

func startupSavedTrustDecision(cwd: String, settingsManager: SettingsManager) -> ProjectTrustUpdate? {
    let decisions = settingsManager.getGlobalSettings().projectTrust ?? [:]
    var current = normalizeProjectTrustPathForOptions(cwd)
    while true {
        if let decision = decisions[current] { return ProjectTrustUpdate(path: current, decision: decision) }
        let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
        if parent == current { return nil }
        current = parent
    }
}
