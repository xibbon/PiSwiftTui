import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

func startupThinkingLevel(
    settingsManager: SettingsManager,
    model: Model?,
    restoredLevel: String?,
    scopedModel: ScopedModel?,
    cliLevel: PiSwiftAgent.ThinkingLevel?
) -> PiSwiftAgent.ThinkingLevel {
    if let cliLevel { return cliLevel }
    if let restoredLevel, let level = PiSwiftAgent.ThinkingLevel(rawValue: restoredLevel) { return level }
    if let scopedModel, scopedModel.isThinkingExplicit, let level = scopedModel.thinkingLevel { return level }
    if let model, let level = settingsManager.getModelThinkingLevel(model.provider, model.id) { return level }
    return settingsManager.getDefaultThinkingLevel().flatMap(PiSwiftAgent.ThinkingLevel.init(rawValue:)) ?? DEFAULT_THINKING_LEVEL
}

struct StartupToolSelection: Sendable {
    let initial: InitialToolSelection
    let allowedToolNames: Set<String>?
    let excludedToolNames: Set<String>
    let usesDefaultTools: Bool
}

func selectStartupTools(
    _ args: Args,
    registeredTools: [InitialToolRegistration],
    settingsManager: SettingsManager
) -> StartupToolSelection {
    let noTools: NoToolsMode? = args.noTools == true ? .all : (args.noBuiltinTools == true ? .builtin : nil)
    let excludeTools = args.excludeTools ?? []
    return StartupToolSelection(
        initial: selectInitialTools(
            registeredTools: registeredTools,
            toolNames: args.tools,
            excludeTools: excludeTools,
            noTools: noTools,
            defaultToolNames: settingsManager.getDefaultTools() ?? ["read", "bash", "edit", "write"]
        ),
        allowedToolNames: args.tools.map(Set.init) ?? (noTools == .all ? [] : nil),
        excludedToolNames: Set(excludeTools),
        usesDefaultTools: args.tools == nil && noTools == nil
    )
}

func startupModelScopeMessage(
    _ models: [ScopedModel], quietStartup: QuietStartup, verbose: Bool,
    keybindings: KeybindingsManager = .create()
) -> String? {
    guard !models.isEmpty, quietStartup.showsStartupDetails(verbose: verbose) else { return nil }
    let modelList = models.map { scoped in
        let thinking = scoped.isThinkingExplicit ? ":\((scoped.thinkingLevel ?? .off).rawValue)" : ""
        return "\(scoped.model.id)\(thinking)"
    }.joined(separator: ", ")
    let cycleKeys = keybindings.getKeys(.cycleModelForward).map { key in
        key.split(separator: "+").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: "+")
    }.joined(separator: "/")
    let cycleHint = cycleKeys.isEmpty ? "" : " (\(cycleKeys) to cycle)"
    return "Model scope: \(modelList)\(cycleHint)"
}
