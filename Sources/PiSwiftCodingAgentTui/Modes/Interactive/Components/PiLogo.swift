import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Four cells, two lines. Brand colors use fixed sRGB values in the active color mode.
public func piLogoLines() -> (top: String, bottom: String) {
    let coral = try! MiniTui.rgbColor(228, 138, 122)
    let blue = try! MiniTui.rgbColor(79, 142, 179)
    let yellow = try! MiniTui.rgbColor(234, 182, 93)
    let mode = MiniTui.TerminalColorMode(rawValue: theme.getColorMode()) ?? .color256
    let reset = "\u{001B}[0m"
    let top = "\(MiniTui.foregroundAnsi(coral, mode))\(MiniTui.backgroundAnsi(blue, mode))▀\(reset)\(MiniTui.foregroundAnsi(coral, mode))▀█\(reset) "
    let bottom = "\(MiniTui.foregroundAnsi(blue, mode))█▀\(reset) \(MiniTui.foregroundAnsi(yellow, mode))█\(reset)"
    return (top, bottom)
}

/// Apple Terminal uses a text mark because its half blocks have gaps.
public func supportsPiLogo(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    !isAppleTerminalSession(environment: environment)
}

public func piWordmark() -> String {
    let coral = try! MiniTui.rgbColor(228, 138, 122)
    let yellow = try! MiniTui.rgbColor(234, 182, 93)
    let mode = MiniTui.TerminalColorMode(rawValue: theme.getColorMode()) ?? .color256
    let reset = "\u{001B}[0m"
    return "\(MiniTui.foregroundAnsi(coral, mode))P\(reset)\(MiniTui.foregroundAnsi(yellow, mode))i\(reset)"
}
