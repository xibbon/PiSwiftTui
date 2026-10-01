import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui
import Foundation

func startupCapabilityOverrides(_ settingsManager: SettingsManager) -> MiniTui.TerminalCapabilityOverrides {
    let settings = settingsManager.getTerminalCapabilityOverrides()
    let images: ImageProtocol??
    switch settings.images {
    case .kitty: images = .some(.kitty)
    case .iterm2: images = .some(.iterm2)
    case .disabled: images = .some(nil)
    case .auto, nil: images = nil
    }
    return MiniTui.TerminalCapabilityOverrides(images: images, trueColor: settings.trueColor, hyperlinks: settings.hyperlinks)
}

func applyStartupTerminalSettings(_ settingsManager: SettingsManager) {
    setCapabilityOverrides(startupCapabilityOverrides(settingsManager))
    PiSwiftCodingAgent.setTerminalColorMode(MiniTui.getTerminalColorMode().codingAgentColorMode)
}

func initializeStartupTheme(_ settingsManager: SettingsManager, enableWatcher: Bool = false) {
    applyStartupTerminalSettings(settingsManager)
    loadInitialStartupTheme(settingsManager, enableWatcher: enableWatcher)
}

private func loadInitialStartupTheme(_ settingsManager: SettingsManager, enableWatcher: Bool) {
    markTerminalColorsPending()
    initTheme(resolveThemeSetting(settingsManager.getTheme(), appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? "system",
              enableWatcher: enableWatcher)
}

func loadStartupThemes(_ resources: [ResolvedResource]) -> [HookThemeInfo] {
    var names = Set<String>()
    return resources.compactMap { resource in
        guard resource.enabled, let loaded = try? loadThemeFromPath(resource.path),
              names.insert(loaded.name).inserted else { return nil }
        return HookThemeInfo(name: loaded.name, path: resource.path)
    }
}

func prepareStartupTheme(_ settingsManager: SettingsManager, enableWatcher: Bool = false) async {
    applyStartupTerminalSettings(settingsManager)
    let globalSettings = SettingsManager.inMemory(settingsManager.getGlobalSettings())
    let packages = DefaultPackageManager(cwd: FileManager.default.currentDirectoryPath, agentDir: getAgentDir(),
                                        settingsManager: globalSettings, projectTrusted: false)
    // These Swift startup presenters do not throw. Normal startup reports resource errors later.
    let resources = try? await packages.resolve(onMissing: { _ in .skip })
    setRegisteredThemes(loadStartupThemes(resources?.themes ?? []))
    loadInitialStartupTheme(settingsManager, enableWatcher: enableWatcher)
}

@MainActor
func startStartupTui(_ ui: TUI, settingsManager: SettingsManager) {
    ui.start()
    let setting = settingsManager.getTheme()
    queryStartupTerminalColors(ui) {
        _ = setTheme(resolveThemeSetting(setting, appearance: PiSwiftCodingAgent.getTerminalTheme()) ?? "system")
    }
}

@MainActor
@discardableResult
func queryStartupTerminalColors(_ ui: any TerminalThemeProbing,
                                onColors: @escaping @MainActor () -> Void,
                                onRender: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    requestTerminalColors(ui) { colors in
        PiSwiftCodingAgent.setTerminalColors(colors.codingAgentColors)
        onColors()
        onRender()
    }
}

@MainActor
@discardableResult
func queryStartupTerminalColors(_ ui: TUI, onColors: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    queryStartupTerminalColors(ui, onColors: onColors, onRender: {
        ui.invalidate()
        ui.requestRender()
    })
}
