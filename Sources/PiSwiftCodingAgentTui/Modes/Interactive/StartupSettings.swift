import Foundation
import Synchronization
import MiniTui
import PiSwiftCodingAgent

@MainActor
func applyInteractiveTerminalCapabilities(_ settings: SettingsManager) {
    let overrides = settings.getTerminalCapabilityOverrides()
    var images: ImageProtocol??
    switch overrides.images {
    case .kitty: images = .some(.kitty)
    case .iterm2: images = .some(.iterm2)
    case .disabled: images = .some(nil)
    case .auto, .none: images = nil
    }
    setCapabilityOverrides(MiniTui.TerminalCapabilityOverrides(images: images, trueColor: overrides.trueColor, hyperlinks: overrides.hyperlinks))
    PiSwiftCodingAgent.setTerminalColorMode(MiniTui.getTerminalColorMode().codingAgentColorMode)
    ensurePngTranscoder()
}

final class ManagedToolStatuses: Sendable {
    private let values = Mutex<[ToolStatus]>([])
    func append(_ value: ToolStatus) { values.withLock { $0.append(value) } }
    func drain() -> [ToolStatus] { values.withLock { let result = $0; $0.removeAll(); return result } }
}

/// Raw read for the CLI startup screens, which run before a session SettingsManager exists.
/// Interactive mode uses SettingsManager.getClearOnShrink(). Keep the setting out of MiniTui:
/// the host owns settings and environment precedence.
public func getClearOnShrink(cwd: String = FileManager.default.currentDirectoryPath,
                             agentDir: String = getAgentDir(),
                             loadProjectSettings: Bool = true,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    let global = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json")
    let project = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("settings.json")
    for url in loadProjectSettings ? [project, global] : [global] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terminal = object["terminal"] as? [String: Any],
              let value = terminal["clearOnShrink"] as? Bool else { continue }
        return value
    }
    return environment["PI_CLEAR_ON_SHRINK"] == "1"
}
