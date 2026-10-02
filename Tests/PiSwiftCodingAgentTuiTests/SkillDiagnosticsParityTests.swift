import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class SkillDiagnosticsResources: ResourceLoader {
    let winner = "/tmp/pi-skills/xogot/SKILL.md"
    let loser = "/tmp/agents-skills/xogot/SKILL.md"
    let metadata = PathMetadata(source: "auto", scope: "user", origin: "top-level")

    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
        ([Skill(name: "xogot", description: "Skill", filePath: winner, baseDir: "/tmp/pi-skills/xogot",
                sourceInfo: SourceInfo(path: winner, metadata: metadata))], [
            ResourceDiagnostic(type: "warning", message: "description exceeds 1024 characters (1093)", path: loser),
            ResourceDiagnostic(type: "collision", message: "name \"xogot\" collision", path: loser,
                collision: ResourceCollision(resourceType: "skill", name: "xogot", winnerPath: winner, loserPath: loser)),
        ])
    }
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [winner: metadata, loser: metadata] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

@MainActor
@Test func skillDiagnosticsShowWinnerSourceAndPlainSkippedPath() {
    let resources = SkillDiagnosticsResources()
    let session = AgentSession(config: AgentSessionConfig(
        agent: Agent(), sessionManager: .inMemory("/tmp"), settingsManager: .inMemory(),
        resourceLoader: resources,
        modelRegistry: ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    ))
    defer { session.dispose() }
    let mode = InteractiveMode(session: session, version: VERSION)
    mode.showLoadedResources(.init(extensionPaths: [], force: true))
    let output = stripTerminalSequences(mode.loadedResourcesContainer.render(width: 160).joined(separator: "\n"))
    #expect(output.contains("[Skill conflicts]"))
    #expect(output.contains("\"xogot\" collision:"))
    #expect(output.contains("✓ auto (user) \(resources.winner)"))
    #expect(output.contains("✗ \(resources.loser) (skipped)"))
    #expect(!output.contains("auto (user) \(resources.loser)"))
    #expect(output.components(separatedBy: "description exceeds 1024 characters (1093)").count == 2)
}
