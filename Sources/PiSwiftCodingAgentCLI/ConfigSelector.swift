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
            await prepareStartupTheme(settingsManager, enableWatcher: true)
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: cwd, agentDir: agentDir, loadProjectSettings: projectTrusted))
            var resolved = false

            let globalPaths = try? await resolveBuiltinExtensionPaths(settingsManager: settingsManager,
                names: resolvedPaths.extensions.filter { $0.metadata.source == "builtin" }.map { String($0.path.dropFirst(BUILTIN_PATH_PREFIX.count)) },
                cwd: cwd, agentDir: agentDir, projectTrusted: false)
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
                initialProjectMode: initialProjectMode,
                globalResolvedPaths: globalPaths
            )

            ui.addChild(selector)
            ui.setFocus(selector.getResourceList())
            startStartupTui(ui, settingsManager: settingsManager)
        }
    }
}
