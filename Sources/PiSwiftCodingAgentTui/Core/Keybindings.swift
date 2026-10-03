import Foundation
import Synchronization
import MiniTui
import PiSwiftCodingAgent

public typealias KeybindingsConfig = [String: [KeyId]]

public let DEFAULT_APP_KEYBINDINGS: [AppAction: [KeyId]] = [
    .interrupt: [Key.escape],
    .clear: [Key.ctrl("c")],
    .exit: [Key.ctrl("d")],
    .suspend: [Key.ctrl("z")],
    .cycleThinkingLevel: [Key.shift("tab")],
    .cycleModelForward: [Key.ctrl("p")],
    .cycleModelBackward: [Key.shiftCtrl("p")],
    .selectModel: [Key.ctrl("l")],
    .expandTools: [Key.ctrl("o")],
    .toggleThinking: [Key.ctrl("t")],
    .externalEditor: [Key.ctrl("g")],
    .followUp: [Key.alt("enter")],
    .dequeue: [Key.alt("up")],
    .pasteImage: [Key.ctrl("v")],
    .copyMessage: [Key.ctrl("x")],
]

public let DEFAULT_SELECTOR_KEYBINDINGS: KeybindingsConfig = [
    "app.models.save": [Key.ctrl("s")],
    "app.thinking.save": [Key.ctrl("s")],
    "app.models.enableAll": [Key.ctrl("a")],
    "app.models.clearAll": [Key.ctrl("x")],
    "app.models.toggleProvider": [Key.ctrl("p")],
    "app.models.reorderUp": [Key.alt("up")],
    "app.models.reorderDown": [Key.alt("down")],
]

private let activeSelectorHintKeys = Mutex<KeybindingsConfig>(DEFAULT_SELECTOR_KEYBINDINGS)

public func selectorKeyText(_ action: String) -> String {
    formatKeys(activeSelectorHintKeys.withLock { $0[action] ?? [] })
}

public func selectorKeyMatches(_ data: String, _ action: String) -> Bool {
    activeSelectorHintKeys.withLock { $0[action] ?? [] }.contains { matchesKey(data, $0) }
}

// Keep an immutable snapshot for hints without changing manager isolation.
private let activeAppHintKeys = Mutex<[AppAction: [KeyId]]>(DEFAULT_APP_KEYBINDINGS)

func currentAppHintKeys(_ action: AppAction) -> [KeyId] {
    activeAppHintKeys.withLock { $0[action] ?? [] }
}

func appKeyMatches(_ data: String, _ action: AppAction) -> Bool {
    currentAppHintKeys(action).contains { matchesKey(data, $0) }
}

public final class KeybindingsManager {
    private let config: KeybindingsConfig
    private let appActionToKeys: [AppAction: [KeyId]]

    private init(config: KeybindingsConfig) {
        self.config = config
        self.appActionToKeys = KeybindingsManager.buildMaps(config: config)
    }

    public static func create(agentDir: String = getAgentDir()) -> KeybindingsManager {
        let configPath = URL(fileURLWithPath: agentDir).appendingPathComponent("keybindings.json").path
        let config = loadFromFile(configPath)
        let manager = KeybindingsManager(config: config)
        activeAppHintKeys.withLock { $0 = manager.appActionToKeys }
        activeSelectorHintKeys.withLock { $0 = DEFAULT_SELECTOR_KEYBINDINGS.merging(config) { _, configured in configured } }

        var tuiBindings: [String: [KeyId]?] = [:]
        let definitions = TUIKeybindingsManager()
        for (action, keys) in config where definitions.getDefinition(action) != nil {
            tuiBindings[action] = keys
        }
        setKeybindings(TUIKeybindingsManager(userBindings: tuiBindings))

        var editorBindings: [EditorAction: [KeyId]] = [:]
        for (action, keys) in config {
            if let editorAction = EditorAction(rawValue: action) {
                editorBindings[editorAction] = keys
            }
        }
        setEditorKeybindings(EditorKeybindingsManager(config: EditorKeybindingsConfig(editorBindings)))

        return manager
    }

    public static func inMemory(config: KeybindingsConfig = [:]) -> KeybindingsManager {
        let manager = KeybindingsManager(config: config)
        activeSelectorHintKeys.withLock { $0 = DEFAULT_SELECTOR_KEYBINDINGS.merging(config) { _, configured in configured } }
        return manager
    }

    private static func loadFromFile(_ path: String) -> KeybindingsConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            return [:]
        }

        var result: KeybindingsConfig = [:]
        for (action, value) in dict {
            if let key = value as? String {
                result[action] = [key]
            } else if let array = value as? [Any] {
                let keys = array.compactMap { $0 as? String }
                if !keys.isEmpty {
                    result[action] = keys
                }
            }
        }
        return result
    }

    private static func buildMaps(config: KeybindingsConfig) -> [AppAction: [KeyId]] {
        var map = DEFAULT_APP_KEYBINDINGS
        for (action, keys) in config {
            if let appAction = AppAction(rawValue: action) {
                map[appAction] = keys
            }
        }
        return map
    }

    public func matches(_ data: String, _ action: AppAction) -> Bool {
        guard let keys = appActionToKeys[action] else { return false }
        for key in keys {
            if matchesKey(data, key) { return true }
        }
        return false
    }

    public func getKeys(_ action: AppAction) -> [KeyId] {
        return appActionToKeys[action] ?? []
    }

    public func getDisplayString(_ action: AppAction) -> String {
        let keys = getKeys(action)
        if keys.isEmpty { return "" }
        if keys.count == 1 { return keys[0] }
        return keys.joined(separator: "/")
    }

    public func getEffectiveConfig() -> KeybindingsConfig {
        var result: KeybindingsConfig = [:]
        for (action, keys) in DEFAULT_EDITOR_KEYBINDINGS {
            result[action.rawValue] = keys
        }
        for (action, keys) in DEFAULT_APP_KEYBINDINGS {
            result[action.rawValue] = keys
        }
        for (action, keys) in config {
            result[action] = keys
        }
        return result
    }
}

extension KeybindingsManager: HookKeybindings {}
