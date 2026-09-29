import Foundation
import MiniTui
import PiSwiftCodingAgent

public func parseAutoThemeSetting(_ setting: String?) -> (light: String, dark: String)? {
    guard let setting else { return nil }
    let parts = setting.split(separator: "/", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
}

@MainActor
public final class InteractiveThemeController {
    private let ui: TUI
    private let getSettingsManager: () -> SettingsManager
    private let showError: (String) -> Void
    private let onChanged: () -> Void
    private var currentThemeSetting: String?
    private var terminalTheme = themeBackgroundFromEnvironment().theme
    private var activeThemeName: String?
    private var autoSyncEnabled = false
    private var unsubscribe: (() -> Void)?

    public init(ui: TUI, getSettingsManager: @escaping () -> SettingsManager,
                showError: @escaping (String) -> Void, onChanged: @escaping () -> Void,
                initialThemeSetting: String? = nil) {
        self.ui = ui
        self.getSettingsManager = getSettingsManager
        self.showError = showError
        self.onChanged = onChanged
        self.currentThemeSetting = initialThemeSetting
        let setting = initialThemeSetting ?? getSettingsManager().getTheme()
        if let pair = parseAutoThemeSetting(setting) {
            activeThemeName = terminalTheme == .light ? pair.light : pair.dark
        } else { activeThemeName = setting }
        initTheme(activeThemeName, enableWatcher: true)
        bindListener()
    }

    public func getThemeSelection() -> String? {
        currentThemeSetting ?? getSettingsManager().getTheme() ?? activeThemeName
    }

    public func applyFromSettings() async {
        let setting = currentThemeSetting ?? getSettingsManager().getTheme()
        if let pair = parseAutoThemeSetting(setting) {
            terminalTheme = await detectTerminalTheme(ui: ui)
            setAutoSync(true)
            _ = applyThemeName(terminalTheme == .light ? pair.light : pair.dark, showError: true)
        } else if let setting {
            setAutoSync(false)
            _ = applyThemeName(setting, showError: true)
        } else {
            setAutoSync(false)
            // Persist only a terminal response or a valid COLORFGBG background hint.
            if let background = await ui.queryTerminalColors(timeoutMs: 100, onLateReply: nil).background {
                terminalTheme = PiSwiftCodingAgentTui.terminalTheme(for: background)
                if applyThemeName(terminalTheme.rawValue).success {
                    getSettingsManager().setTheme(terminalTheme.rawValue)
                    await getSettingsManager().flush()
                }
            } else {
                let hint = themeBackgroundFromEnvironment()
                terminalTheme = hint.theme
                if applyThemeName(terminalTheme.rawValue).success && hint.confident {
                    getSettingsManager().setTheme(terminalTheme.rawValue)
                    await getSettingsManager().flush()
                }
            }
        }
    }

    public func setThemeSetting(_ setting: String) async {
        currentThemeSetting = setting
        await applyFromSettings()
    }

    public func setThemeName(_ name: String, showError: Bool = false) -> (success: Bool, error: String?) {
        setAutoSync(false)
        let result = applyThemeName(name, showError: showError)
        if result.success { currentThemeSetting = name }
        return result
    }

    public func setThemeInstance(_ instance: Theme) {
        setAutoSync(false)
        PiSwiftCodingAgent.setThemeInstance(instance)
        activeThemeName = "<in-memory>"
        ui.invalidate()
        onChanged()
    }

    public func preview(_ setting: String) {
        let pair = parseAutoThemeSetting(setting)
        let name = pair.map { terminalTheme == .light ? $0.light : $0.dark } ?? setting
        if setTheme(name, enableWatcher: true).success {
            ui.invalidate()
            ui.requestRender()
        }
    }

    public func disableAutoSync() { setAutoSync(false) }
    public func getTerminalTheme() -> TerminalColorScheme { terminalTheme }
    public func rebindTui() {
        unsubscribe?()
        bindListener()
        ui.setTerminalColorSchemeNotifications(autoSyncEnabled)
    }
    public func dispose() {
        setAutoSync(false)
        unsubscribe?()
        unsubscribe = nil
    }

    private func applyThemeName(_ name: String, showError: Bool = false) -> (success: Bool, error: String?) {
        let result = setTheme(name, enableWatcher: true)
        activeThemeName = result.success ? name : "dark"
        ui.invalidate()
        onChanged()
        if !result.success && showError {
            self.showError("Failed to load theme \"\(name)\": \(result.error ?? "Unknown error")\nFell back to dark theme.")
        }
        return result
    }
    private func setAutoSync(_ enabled: Bool) {
        guard enabled != autoSyncEnabled else { return }
        autoSyncEnabled = enabled
        ui.setTerminalColorSchemeNotifications(enabled)
    }
    private func bindListener() {
        unsubscribe = ui.onTerminalColorSchemeChange { [weak self] scheme in
            guard let self, self.autoSyncEnabled else { return }
            self.terminalTheme = scheme
            guard let pair = parseAutoThemeSetting(self.currentThemeSetting ?? self.getSettingsManager().getTheme()) else {
                self.setAutoSync(false)
                return
            }
            let name = scheme == .light ? pair.light : pair.dark
            if name != self.activeThemeName { _ = self.applyThemeName(name) }
        }
    }
}

private func themeBackgroundFromEnvironment() -> (theme: TerminalColorScheme, confident: Bool) {
    let values = (ProcessInfo.processInfo.environment["COLORFGBG"] ?? "").split(separator: ";").reversed()
    guard let index = values.compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }).first(where: { (0...255).contains($0) }) else { return (.dark, false) }
    let rgb: (Int, Int, Int)
    if index < 16 {
        let colors = [(0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),(192,192,192),
                      (128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)]
        rgb = colors[index]
    } else if index < 232 {
        let cube = index - 16
        func channel(_ value: Int) -> Int { value == 0 ? 0 : 55 + value * 40 }
        rgb = (channel(cube / 36), channel((cube % 36) / 6), channel(cube % 6))
    } else {
        let gray = 8 + (index - 232) * 10
        rgb = (gray, gray, gray)
    }
    return (terminalTheme(for: RgbColor(r: rgb.0, g: rgb.1, b: rgb.2)), true)
}
