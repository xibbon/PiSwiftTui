import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

@Suite struct StartupDiagnosticsV085Tests {
    @Test func interactiveWarningsRemainInChatAndDuplicatesAreRemoved() {
        let warning = ResourceDiagnostic(type: "warning", message: "Invalid settings file /tmp/agent/settings.json: invalid value")
        let status = ResourceDiagnostic(type: "info", message: "Catalog loaded")
        let result = startupDiagnosticDisposition(startup: [warning], runtime: [warning, status], isInteractive: true)
        #expect(result.diagnostics.map(\.message) == [warning.message, status.message])
        #expect(!result.shouldPrint)
        #expect(!result.hasRuntimeErrors)
    }

    @Test func onlyRuntimeErrorsTriggerInteractiveTerminalOutputAndFailure() {
        let error = ResourceDiagnostic(type: "error", message: "Failed to load extension")
        let startupOnly = startupDiagnosticDisposition(startup: [error], runtime: [], isInteractive: true)
        #expect(!startupOnly.shouldPrint)
        #expect(!startupOnly.hasRuntimeErrors)
        let runtimeError = startupDiagnosticDisposition(startup: [error], runtime: [error], isInteractive: true)
        #expect(runtimeError.shouldPrint)
        #expect(runtimeError.hasRuntimeErrors)
        #expect(runtimeError.diagnostics.count == 1)
    }

    @Test func nonInteractiveModesPrintWarningsWithoutFailure() {
        let warning = ResourceDiagnostic(type: "warning", message: "Invalid settings file /tmp/settings.json")
        let result = startupDiagnosticDisposition(startup: [warning], runtime: [], isInteractive: false)
        #expect(result.shouldPrint)
        #expect(!result.hasRuntimeErrors)
        #expect(result.diagnostics.first?.message == warning.message)
    }

    @Test func resourceWarningsAppearOnceWhenStartupResourcesAreShown() {
        let resource = ResourceDiagnostic(type: "warning", message: "description exceeds 1024 characters (1093)", path: "/tmp/xogot/SKILL.md")
        let settings = ResourceDiagnostic(type: "warning", message: "Invalid settings file")
        let shown = startupDiagnosticDisposition(startup: [settings], runtime: [resource], isInteractive: true,
            resources: [resource], resourcesShown: true)
        #expect(shown.diagnostics.map(\.message) == [settings.message])
        #expect(!shown.shouldPrint)
        let quiet = startupDiagnosticDisposition(startup: [], runtime: [resource], isInteractive: true,
            resources: [resource], resourcesShown: false)
        #expect(quiet.diagnostics.map(\.message) == [resource.message])
        let printed = startupDiagnosticDisposition(startup: [], runtime: [resource], isInteractive: false,
            resources: [resource], resourcesShown: true)
        #expect(printed.diagnostics.map(\.message) == [resource.message])
        #expect(printed.shouldPrint)
    }

    @Test func resourceErrorsRemainVisibleBeforeStartupFailure() {
        let error = ResourceDiagnostic(type: "error", message: "Resource failed", path: "/tmp/SKILL.md")
        let result = startupDiagnosticDisposition(startup: [], runtime: [error], isInteractive: true,
            resources: [error], resourcesShown: true)
        #expect(result.hasRuntimeErrors)
        #expect(result.shouldPrint)
        #expect(result.diagnostics.map(\.message) == [error.message])
    }
}
