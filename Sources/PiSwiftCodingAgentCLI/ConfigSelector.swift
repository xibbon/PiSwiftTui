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
    projectTrusted: Bool = true,
    prepareTheme: (@MainActor (SettingsManager) async -> Void)? = nil,
    installKeybindings: (@MainActor (KeybindingsManager) -> Void)? = nil,
    startUI: (@MainActor (TUI, ConfigSelectorComponent, SettingsManager, () -> Void) -> Void)? = nil
) async {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            if let prepareTheme {
                await prepareTheme(settingsManager)
            } else {
                await prepareStartupTheme(settingsManager, enableWatcher: true)
            }
            let keybindings = KeybindingsManager.load(agentDir: agentDir)
            if let installKeybindings {
                installKeybindings(keybindings)
            } else {
                keybindings.activate()
            }
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: agentDir)
            ui.setClearOnShrink(getClearOnShrink(cwd: cwd, agentDir: agentDir, loadProjectSettings: projectTrusted))
            var resolved = false
            let close: () -> Void = {
                guard !resolved else { return }
                resolved = true
                if startUI == nil {
                    ui.stop()
                    stopThemeWatcher()
                }
                continuation.resume()
            }

            let globalPaths = try? await resolveBuiltinExtensionPaths(settingsManager: settingsManager,
                names: resolvedPaths.extensions.filter { $0.metadata.source == "builtin" }.map { String($0.path.dropFirst(BUILTIN_PATH_PREFIX.count)) },
                cwd: cwd, agentDir: agentDir, projectTrusted: false)
            let selector = ConfigSelectorComponent(
                resolvedPaths: resolvedPaths,
                settingsManager: settingsManager,
                cwd: cwd,
                agentDir: agentDir,
                onClose: close,
                onExit: {
                    ui.stop()
                    stopThemeWatcher()
                    Darwin.exit(0)
                },
                requestRender: {
                    ui.requestRender()
                },
                initialProjectMode: initialProjectMode,
                globalResolvedPaths: globalPaths
            )

            ui.addChild(selector)
            ui.setFocus(selector.getResourceList())
            if let startUI {
                startUI(ui, selector, settingsManager, close)
            } else {
                startStartupTui(ui, settingsManager: settingsManager)
            }
        }
    }
}
