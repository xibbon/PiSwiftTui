import Foundation
import MiniTui
import PiSwiftCodingAgent

@MainActor
public protocol TerminalThemeProbing: AnyObject {
    func queryTerminalColors(
        timeoutMs: Int,
        onLateReply: (@MainActor (MiniTui.TerminalColors) -> Void)?
    ) async -> MiniTui.TerminalColors
}

extension TUI: TerminalThemeProbing {}

public func terminalThemeFromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
) -> TerminalColorScheme {
    PiSwiftCodingAgent.detectColorFgBgTheme(env: environment) == .light ? .light : .dark
}

public func terminalTheme(for color: MiniTui.RgbColor) -> TerminalColorScheme {
    PiSwiftCodingAgent.terminalAppearance(color.codingAgentColor) == .light ? .light : .dark
}

/// Use the shared library detection rules after the terminal query.
@MainActor
public func detectTerminalTheme(
    ui: any TerminalThemeProbing,
    timeoutMs: Int = 100,
    reportedScheme: TerminalColorScheme? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> TerminalColorScheme {
    let colors = await ui.queryTerminalColors(timeoutMs: timeoutMs, onLateReply: nil)
    return PiSwiftCodingAgent.detectTerminalTheme(
        colors: colors.codingAgentColors,
        reportedScheme: reportedScheme?.codingAgentAppearance,
        env: environment
    ) == .light ? .light : .dark
}

/// Apply the first query result and any late replies. The task ends after the first result.
@MainActor
@discardableResult
public func requestTerminalColors(
    _ ui: any TerminalThemeProbing,
    apply: @escaping @MainActor (MiniTui.TerminalColors) -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        let colors = await ui.queryTerminalColors(timeoutMs: 100, onLateReply: apply)
        apply(colors)
    }
}
