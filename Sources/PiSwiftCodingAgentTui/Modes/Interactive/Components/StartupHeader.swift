import MiniTui
import PiSwiftCodingAgent

public func buildStartupHeader(version: String, keybindings: KeybindingsManager, expanded: Bool) -> String {
    let logo = piLogoLines()
    func displayKeys(_ keys: String) -> String {
        #if os(macOS)
        return keys.components(separatedBy: "/").map { key in
            key.components(separatedBy: "+").map { $0.lowercased() == "alt" ? "option" : $0 }.joined(separator: "+")
        }.joined(separator: "/")
        #else
        return keys
        #endif
    }
    func hint(_ action: AppAction, _ description: String) -> String {
        rawKeyHint(key(action), description)
    }
    func key(_ action: AppAction) -> String { displayKeys(appKey(keybindings, action)) }
    let onboarding = theme.fg(.dim, "Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.")
    let instructions: String
    if expanded {
        instructions = [
            hint(.interrupt, "to interrupt"),
            hint(.clear, "to clear"),
            rawKeyHint("\(key(.clear)) twice", "to exit"),
            hint(.exit, "to exit (empty)"),
            hint(.suspend, "to suspend"),
            rawKeyHint(displayKeys(editorKey(.deleteToLineEnd)), "to delete to end"),
            hint(.cycleThinkingLevel, "to cycle thinking level"),
            rawKeyHint("\(key(.cycleModelForward))/\(key(.cycleModelBackward))", "to cycle models"),
            hint(.selectModel, "to select model"),
            hint(.expandTools, "to expand tools"),
            hint(.toggleThinking, "to expand thinking"),
            hint(.externalEditor, "for external editor"),
            rawKeyHint("/", "for commands"),
            rawKeyHint("!", "to run bash"),
            rawKeyHint("!!", "to run bash (no context)"),
            hint(.followUp, "to queue follow-up"),
            hint(.dequeue, "to edit all queued messages"),
            hint(.pasteImage, "to paste files on macOS, images, or text"),
            rawKeyHint("drop files", "to attach"),
        ].joined(separator: "\n")
    } else {
        instructions = [
            hint(.interrupt, "interrupt"),
            rawKeyHint("\(key(.clear))/\(key(.exit))", "clear/exit"),
            rawKeyHint("/", "commands"),
            rawKeyHint("!", "bash"),
            hint(.expandTools, "more"),
        ].joined(separator: theme.fg(.muted, " · "))
    }
    let withLogo = "\(logo.top) \(theme.fg(.dim, "v\(version)"))\n\(logo.bottom) \(instructions)"
    if expanded { return "\(withLogo)\n\n\(onboarding)" }
    let compactOnboarding = theme.fg(.dim, "Press \(key(.expandTools)) to show full startup help and loaded resources.")
    return "\(withLogo)\n\(compactOnboarding)\n\n\(onboarding)"
}
