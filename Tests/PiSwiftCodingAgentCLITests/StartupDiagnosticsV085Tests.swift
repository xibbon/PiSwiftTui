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
}
