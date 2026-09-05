import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

private let officialPackageName = "@earendil-works/pi-coding-agent"
private let officialAppName = "pi"
private let officialConfigDirName = ".pi"

typealias FirstTimeSetupPresenter = @Sendable (SettingsManager) async -> FirstTimeSetupResult?

func shouldRunFirstTimeSetup(
    settingsPath: String = getSettingsPath(),
    env: [String: String] = ProcessInfo.processInfo.environment,
    packageName: String = PACKAGE_NAME,
    appName: String = APP_NAME,
    configDirName: String = CONFIG_DIR_NAME,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> Bool {
    guard packageName == officialPackageName,
          appName == officialAppName,
          configDirName == officialConfigDirName else {
        return false
    }
    guard env["PI_EXPERIMENTAL"] == "1" else {
        return false
    }
    guard env[ENV_AGENT_DIR] == nil || env[ENV_AGENT_DIR]?.isEmpty == true else {
        return false
    }
    return !fileExists(settingsPath)
}

@discardableResult
func runFirstTimeSetupIfNeeded(
    settingsManager: SettingsManager,
    settingsPath: String = getSettingsPath(),
    env: [String: String] = ProcessInfo.processInfo.environment,
    isInteractive: Bool,
    presenter: FirstTimeSetupPresenter? = nil
) async -> Bool {
    guard isInteractive,
          shouldRunFirstTimeSetup(settingsPath: settingsPath, env: env) else {
        return false
    }

    let result = if let presenter {
        await presenter(settingsManager)
    } else {
        await presentFirstTimeSetup(settingsManager: settingsManager)
    }

    if let result {
        settingsManager.setTheme(result.themeName)
        settingsManager.setEnableAnalytics(result.shareAnalytics)
    }
    return true
}

func presentFirstTimeSetup(settingsManager: SettingsManager) async -> FirstTimeSetupResult? {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            initTheme(settingsManager.getTheme(), enableWatcher: false)
            applyStartupTerminalSettings(settingsManager)
            let ui = TUI(terminal: ProcessTerminal(), showHardwareCursor: settingsManager.getShowHardwareCursor(), logDirectory: getAgentDir())
            ui.setClearOnShrink(getClearOnShrink(cwd: FileManager.default.currentDirectoryPath, agentDir: getAgentDir(), loadProjectSettings: false))
            ui.start()
            let initialTheme: String
            if let configuredTheme = settingsManager.getTheme() {
                initialTheme = configuredTheme
            } else {
                initialTheme = await detectTerminalTheme(ui: ui, timeoutMs: 100).rawValue
            }
            _ = setTheme(initialTheme, enableWatcher: false)
            var resolved = false

            let finish: (FirstTimeSetupResult?) -> Void = { result in
                guard !resolved else { return }
                resolved = true
                ui.stop()
                stopThemeWatcher()
                continuation.resume(returning: result)
            }

            let component = FirstTimeSetupComponent(
                detectedThemeName: initialTheme,
                onThemePreview: { themeName in
                    _ = setTheme(themeName, enableWatcher: false)
                    ui.requestRender()
                },
                onSubmit: { result in
                    finish(result)
                },
                onCancel: {
                    finish(nil)
                }
            )

            ui.addChild(component)
            ui.setFocus(component)
            ui.requestRender()
        }
    }
}
