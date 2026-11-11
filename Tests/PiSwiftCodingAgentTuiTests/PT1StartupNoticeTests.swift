import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PT1NoticeResources: ResourceLoader {
    let path: String
    let metadata: PathMetadata
    init(root: String) {
        path = root + "/index.swift"
        metadata = PathMetadata(source: "npm:example", scope: "user", origin: "package",
            baseDir: root, changelogPath: root + "/CHANGELOG.md")
    }
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [path], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [path: metadata] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

@MainActor @Suite(.serialized)
struct PT1StartupNoticeTests {
    // v1.5.2 PT1: interactive-mode-extension-changelog.test.ts:220,228.
    @Test func firstSeenExtensionStaysQuietThenShowsExactUpdateNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt1-notices-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"name":"example","version":"1.1.0"}"#.write(to: root.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        try "## [1.1.0]\n\nA new feature.\n".write(to: root.appendingPathComponent("CHANGELOG.md"),
            atomically: true, encoding: .utf8)
        let settings = SettingsManager.inMemory()
        settings.setQuietStartup(.off)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let session = AgentSession(config: AgentSessionConfig(agent: Agent(),
            sessionManager: .inMemory(root.path), settingsManager: settings,
            resourceLoader: PT1NoticeResources(root: root.path), modelRegistry: registry))
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: VERSION)
        mode.prepareStartupNotices()
        #expect(!toolTestText(mode.startupHeaderContainer).contains("Extension Updates"))
        let key = #"{"source":"npm:example","scope":"user"}"#
        #expect(settings.getExtensionChangelogVersion(key) == "1.1.0")
        settings.setExtensionChangelogVersion(key, version: "1.0.0")
        mode.prepareStartupNotices()
        let open = toolTestText(mode.startupHeaderContainer)
        #expect(open.contains("Extension Updates"))
        #expect(open.contains("example"))
        #expect(open.contains("A new feature."))
        settings.setCollapseChangelog(true)
        mode.refreshStartupHeader()
        let collapsed = toolTestText(mode.startupHeaderContainer)
        #expect(collapsed.contains("Updated example to v1.1.0."))
        #expect(!collapsed.contains("A new feature."))
    }

    // v1.5.2 PT1: interactive-mode-model-scope.test.ts:39.
    @Test func fullscreenHeaderOwnsModelScopeLine() {
        let model = t3aModel("scope-model")
        let session = t3aSession(model: model)
        defer { session.dispose() }
        let mode = InteractiveMode(session: session, version: VERSION,
            scopedModels: [ScopedModel(model: model, thinkingLevel: .high, isThinkingExplicit: true)],
            tuiMode: .fullscreen)
        mode.refreshStartupHeader()
        #expect(toolTestText(mode.startupHeaderContainer).contains("Model scope: scope-model:high"))
        #expect(!toolTestText(mode.chatContainer).contains("Model scope:"))
    }
}
