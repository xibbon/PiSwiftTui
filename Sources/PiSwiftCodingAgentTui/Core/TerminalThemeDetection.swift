import Foundation
import MiniTui

@MainActor
public protocol TerminalThemeProbing: AnyObject {
    func queryTerminalColors(
        timeoutMs: Int,
        onLateReply: (@MainActor (TerminalColors) -> Void)?
    ) async -> TerminalColors
}

extension TUI: TerminalThemeProbing {}

public func terminalThemeFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> TerminalColorScheme {
    guard let colorFgBg = environment["COLORFGBG"] else { return .dark }
    let parts = colorFgBg.split(separator: ";")
    guard parts.count >= 2, let background = Int(parts[1]) else { return .dark }
    return background < 8 ? .dark : .light
}

public func terminalTheme(for color: RgbColor) -> TerminalColorScheme {
    func linear(_ channel: Int) -> Double {
        let value = Double(channel) / 255
        return value <= 0.03928
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    let luminance = 0.2126 * linear(color.r)
        + 0.7152 * linear(color.g)
        + 0.0722 * linear(color.b)
    return luminance >= 0.5 ? .light : .dark
}

/// The reported background decides, then a light/dark report the terminal sent earlier, then
/// `COLORFGBG`, then dark (upstream v0.99.1 `detectTerminalTheme`).
@MainActor
public func detectTerminalTheme(
    ui: any TerminalThemeProbing,
    timeoutMs: Int = 100,
    reportedScheme: TerminalColorScheme? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> TerminalColorScheme {
    let colors = await ui.queryTerminalColors(timeoutMs: timeoutMs, onLateReply: nil)
    if let background = colors.background {
        return terminalTheme(for: background)
    }
    if let reportedScheme {
        return reportedScheme
    }
    return terminalThemeFromEnvironment(environment)
}
