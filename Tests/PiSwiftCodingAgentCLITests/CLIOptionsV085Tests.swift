import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

@Suite struct CLIOptionsV085Tests {
    @Test func endOfOptionsRetainsDashPromptsAndFiles() throws {
        let options = try CLIOptions.parse(PiCodingAgentCLI.preprocessArguments([
            "--print", "before", "--", "- Summarize these points", "@notes.md", "--thinking", "high", "-ne", "--list-models=foo",
        ]))
        let args = options.toArgs()
        #expect(args.print == true)
        #expect(args.thinking == nil)
        #expect(args.noExtensions == nil)
        #expect(args.fileArgs == ["notes.md"])
        #expect(args.messages == ["before", "- Summarize these points", "--thinking", "high", "-ne", "--list-models=foo"])
    }

    @Test func endOfOptionsDoesNotRouteCommands() throws {
        let input = ["--", "auth", "--help"]
        #expect(PiCodingAgentCLI.preprocessArguments(input) == input)
        #expect(try CLIOptions.parse(input).rawMessages == ["auth", "--help"])
    }

    @Test func sessionNamesAreTrimmed() throws {
        #expect(normalizeSessionName("  named session  ") == "named session")
        #expect(normalizeSessionName(" \n\t ") == nil)
        #expect(throws: (any Error).self) { try CLIOptions.parse(["--name", "   "]) }
        #expect(try CLIOptions.parse(["--name", " named "]).sessionName == " named ")
    }

    @Test func useThemeAcceptsAutoPairAndRejectsMissingValue() throws {
        #expect(try CLIOptions.parse(["--use-theme", "dark/light"]).useTheme == "dark/light")
        #expect(throws: (any Error).self) { try CLIOptions.parse(["--use-theme"]) }
        #expect(throws: (any Error).self) { try CLIOptions.parse(["--use-theme", "--print"]) }
        #expect(throws: (any Error).self) { try CLIOptions.parse(["--use-theme=-bad"]) }
    }

    @Test func terminalOverridesDistinguishAutoAndDisabledImages() {
        let settings = SettingsManager.inMemory()
        #expect(startupCapabilityOverrides(settings).images == nil)
        var values = Settings()
        values.terminal = TerminalSettings(hyperlinks: .enabled(false), trueColor: .enabled(true), images: .disabled)
        settings.applyOverrides(values)
        let overrides = startupCapabilityOverrides(settings)
        #expect(overrides.images != nil)
        #expect(overrides.images! == nil)
        #expect(overrides.trueColor == true)
        #expect(overrides.hyperlinks == false)
        #expect(settings.getShowHardwareCursor() == (ProcessInfo.processInfo.environment["PI_HARDWARE_CURSOR"] == "1"))
    }

    @Test func startupThinkingUsesPerModelDefaultsAndExplicitPrecedence() {
        let settings = SettingsManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        #expect(startupThinkingLevel(settingsManager: settings, model: model, restoredLevel: nil, scopedModel: nil, cliLevel: nil) == DEFAULT_THINKING_LEVEL)
        settings.setDefaultThinkingLevel("low")
        settings.setModelThinkingLevel(model.provider, model.id, .high)
        #expect(startupThinkingLevel(settingsManager: settings, model: model, restoredLevel: nil, scopedModel: nil, cliLevel: nil) == .high)
        let scoped = ScopedModel(model: model, thinkingLevel: .minimal, isThinkingExplicit: true)
        #expect(startupThinkingLevel(settingsManager: settings, model: model, restoredLevel: nil, scopedModel: scoped, cliLevel: nil) == .minimal)
        #expect(startupThinkingLevel(settingsManager: settings, model: model, restoredLevel: "medium", scopedModel: scoped, cliLevel: nil) == .medium)
        #expect(startupThinkingLevel(settingsManager: settings, model: model, restoredLevel: "medium", scopedModel: scoped, cliLevel: .off) == .off)
    }

    @Test func startupToolsRespectDefaultsFlagsAndExclusions() {
        let settings = SettingsManager.inMemory()
        var values = Settings()
        values.defaultTools = ["read", "grep", "find"]
        settings.applyOverrides(values)
        var args = Args()
        // T1 replaces startupToolNames with the shared selection and string names. Keep all cases.
        let registered = ToolName.allCases.map { InitialToolRegistration(name: $0.rawValue, isBuiltin: true) }
        func activeNames(_ args: Args) -> [String] {
            selectStartupTools(args, registeredTools: registered, settingsManager: settings).initial.activeToolNames
        }
        #expect(activeNames(args) == ["read", "grep", "find"])
        args.excludeTools = ["find"]
        #expect(activeNames(args) == ["read", "grep"])
        args.noTools = true
        #expect(activeNames(args).isEmpty)
        args.tools = ["bash", "find"]
        #expect(activeNames(args) == ["bash"])
    }

    @Test func savedTrustMarkerUsesClosestStoredAncestor() {
        let settings = SettingsManager.inMemory()
        settings.setProjectTrust("/tmp/pi-trust-parent", trusted: true)
        #expect(startupSavedTrustDecision(cwd: "/tmp/pi-trust-parent/child", settingsManager: settings) == ProjectTrustUpdate(path: normalizeProjectTrustPathForOptions("/tmp/pi-trust-parent"), decision: true))
        settings.setProjectTrust("/tmp/pi-trust-parent/child", trusted: false)
        #expect(startupSavedTrustDecision(cwd: "/tmp/pi-trust-parent/child", settingsManager: settings)?.decision == false)
        #expect(startupSavedTrustDecision(cwd: "/tmp/unrelated-trust", settingsManager: settings) == nil)
    }

    @Test func fileArgumentsStripUtf8Bom() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("prompt.txt")
        try Data([0xef, 0xbb, 0xbf] + Array("prompt text".utf8)).write(to: path)
        let processed = try processFileArguments([path.path])
        #expect(processed.textContent.contains("prompt text"))
        #expect(!processed.textContent.contains("\u{feff}"))
    }

    @Test func invalidSessionIsRejectedWithoutChangingTheFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try "not a session".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        var args = Args()
        args.session = path.path
        #expect(throws: (any Error).self) { try createSessionManager(args, cwd: "/tmp", resumeSession: nil) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "not a session")
    }
}
