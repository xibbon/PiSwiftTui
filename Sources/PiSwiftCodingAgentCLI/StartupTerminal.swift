import MiniTui
import PiSwiftCodingAgent

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
}
