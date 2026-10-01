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

public func resolveThemeSetting(_ setting: String?, appearance: ThemeAppearance) -> String? {
    if let pair = parseAutoThemeSetting(setting) {
        return appearance == .light ? pair.light : pair.dark
    }
    return setting
}

@MainActor
public protocol ThemeControllerUI: TerminalThemeProbing {
    func invalidate()
    func requestRender(force: Bool)
    func setTerminalColorSchemeNotifications(_ enabled: Bool)
    func onTerminalColorSchemeChange(_ listener: @escaping (TerminalColorScheme) -> Void) -> () -> Void
}

public extension ThemeControllerUI {
    func requestRender() { requestRender(force: false) }
}

extension TUI: ThemeControllerUI {}

@MainActor
public final class InteractiveThemeController {
    private let ui: any ThemeControllerUI
    private let getSettingsManager: () -> SettingsManager
    private let showError: (String) -> Void
    private let onChanged: () -> Void
    private var currentThemeSetting: String?
    private var terminalColors: MiniTui.TerminalColors?
    private var activeThemeName: String?
    private var autoSyncEnabled = false
    private var unsubscribe: (() -> Void)?
    private var terminalColorQuery: Task<Void, Never>?

    public init(ui: any ThemeControllerUI, getSettingsManager: @escaping () -> SettingsManager,
                showError: @escaping (String) -> Void, onChanged: @escaping () -> Void,
                initialThemeSetting: String? = nil) {
        self.ui = ui
        self.getSettingsManager = getSettingsManager
        self.showError = showError
        self.onChanged = onChanged
        self.currentThemeSetting = initialThemeSetting
        activeThemeName = resolveThemeName()
        PiSwiftCodingAgent.setTerminalColorMode(MiniTui.getTerminalColorMode().codingAgentColorMode)
        markTerminalColorsPending()
        initTheme(activeThemeName, enableWatcher: true)
        bindListener()
    }

    public func getThemeSelection() -> String? {
        currentThemeSetting ?? getSettingsManager().getTheme() ?? activeThemeName
    }

    /// Apply the setting at once. Terminal colors update the theme when they arrive.
    public func applyFromSettings() {
        let setting = getThemeSetting()
        let name = resolveThemeName()
        setAutoSync(parseAutoThemeSetting(setting) != nil || name == "system")
        _ = applyThemeName(name, showError: setting != nil)
        queryTerminalColors()
    }

    public func waitForTerminalColors() async {
        await terminalColorQuery?.value
    }

    public func setThemeSetting(_ setting: String) {
        currentThemeSetting = setting
        applyFromSettings()
    }

    public func setThemeName(_ name: String, showError: Bool = false) -> (success: Bool, error: String?) {
        setAutoSync(name == "system")
        let result = applyThemeName(name, showError: showError)
        if result.success { currentThemeSetting = name }
        return result
    }

    @discardableResult
    public func setThemeInstance(_ instance: Theme) -> (success: Bool, error: String?) {
        setAutoSync(false)
        PiSwiftCodingAgent.setThemeInstance(instance)
        activeThemeName = "<in-memory>"
        notifyChanged()
        return (true, nil)
    }

    public func preview(_ setting: String) {
        guard let name = resolveThemeSetting(setting, appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? activeThemeName else { return }
        if setTheme(name, enableWatcher: true).success {
            ui.invalidate()
            ui.requestRender()
        }
    }

    public func disableAutoSync() { setAutoSync(false) }
    public func getTerminalTheme() -> TerminalColorScheme {
        PiSwiftCodingAgent.getTerminalTheme() == .light ? .light : .dark
    }
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

    private func getThemeSetting() -> String? {
        currentThemeSetting ?? getSettingsManager().getTheme()
    }

    private func resolveThemeName() -> String {
        resolveThemeSetting(getThemeSetting(), appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? "system"
    }

    private func applyThemeName(_ name: String, showError: Bool = false) -> (success: Bool, error: String?) {
        let result = setTheme(name, enableWatcher: true)
        activeThemeName = result.success ? name : "system"
        notifyChanged()
        if !result.success && showError {
            self.showError("Failed to load theme \"\(name)\": \(result.error ?? "Unknown error")\nFell back to the system theme.")
        }
        return result
    }

    private func queryTerminalColors() {
        terminalColorQuery = requestTerminalColors(ui) { [weak self] in self?.applyTerminalColors($0) }
    }

    private func applyTerminalColors(_ reported: MiniTui.TerminalColors) {
        let next = MiniTui.TerminalColors(
            foreground: reported.foreground ?? terminalColors?.foreground,
            background: reported.background ?? terminalColors?.background,
            palette: reported.palette ?? terminalColors?.palette
        )
        guard terminalColors != next else { return }
        terminalColors = next
        PiSwiftCodingAgent.setTerminalColors(next.codingAgentColors)
        reapplyForTerminal()
        ui.invalidate()
        ui.requestRender()
    }

    private func reapplyForTerminal() {
        guard activeThemeName != "<in-memory>" else { return }
        let name = resolveThemeName()
        if name == "system" || name != activeThemeName { _ = applyThemeName(name) }
    }

    private func setAutoSync(_ enabled: Bool) {
        guard enabled != autoSyncEnabled else { return }
        autoSyncEnabled = enabled
        ui.setTerminalColorSchemeNotifications(enabled)
    }

    private func bindListener() {
        unsubscribe = ui.onTerminalColorSchemeChange { [weak self] scheme in
            guard let self, self.autoSyncEnabled else { return }
            let previous = PiSwiftCodingAgent.getTerminalTheme()
            PiSwiftCodingAgent.setTerminalColorScheme(scheme.codingAgentAppearance)
            if PiSwiftCodingAgent.getTerminalTheme() != previous { self.reapplyForTerminal() }
            self.queryTerminalColors()
        }
    }

    private func notifyChanged() {
        ui.invalidate()
        onChanged()
    }
}
