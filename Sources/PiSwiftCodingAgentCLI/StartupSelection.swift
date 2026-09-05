import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

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

func startupToolNames(_ args: Args, settingsManager: SettingsManager) -> [ToolName] {
    let names: [ToolName]
    if let explicit = args.tools {
        names = explicit
    } else if args.noTools == true || args.noBuiltinTools == true {
        names = []
    } else {
        names = settingsManager.getDefaultTools()?.compactMap(ToolName.init(rawValue:)) ?? [.read, .bash, .edit, .write]
    }
    let excluded = Set(args.excludeTools ?? [])
    return names.filter { !excluded.contains($0.rawValue) }
}
