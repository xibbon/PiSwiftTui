import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

enum MissingSessionCwdChoice: Sendable, Equatable {
    case continueHere
    case fork
    case cancel
}

func openMissingSessionCwdChoice(_ choice: MissingSessionCwdChoice, issue: SessionCwdIssue,
                                sessionDir: String?) throws -> SessionManager? {
    guard let sourcePath = issue.sessionFile else { return nil }
    switch choice {
    case .continueHere:
        return try SessionManager.openValidated(sourcePath, sessionDir, issue.fallbackCwd)
    case .fork:
        return try SessionManager.forkFrom(sourcePath, issue.fallbackCwd, sessionDir)
    case .cancel:
        return nil
    }
}

@MainActor
func selectMissingSessionCwd(_ issue: SessionCwdIssue, settingsManager: SettingsManager,
                             terminal: Terminal? = nil,
                             prepareTheme: Bool = true,
                             startUI: @escaping @MainActor (TUI, SettingsManager) -> Void = startStartupTui)
    async -> MissingSessionCwdChoice {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            if prepareTheme { await prepareStartupTheme(settingsManager) }
            let ui = TUI(terminal: terminal ?? ProcessTerminal(),
                showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: issue.fallbackCwd, agentDir: getAgentDir(),
                loadProjectSettings: false))
            var resolved = false
            let labels = issue.options
            let selector = HookSelectorComponent(title: issue.prompt, options: labels,
                onSelect: { label in
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    let choice: MissingSessionCwdChoice = label == labels[0] ? .continueHere
                        : label == labels[1] ? .fork : .cancel
                    continuation.resume(returning: choice)
                }, onCancel: {
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    continuation.resume(returning: .cancel)
                })
            ui.addChild(selector)
            ui.setFocus(selector)
            // Tests replace this step: the startup color query changes the process-wide theme.
            startUI(ui, settingsManager)
        }
    }
}
