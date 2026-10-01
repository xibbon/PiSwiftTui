import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

@Suite struct T3aCLITests {
    @Test func helpIncludesMcpAndBuiltinExtensionForms() {
        let help = PiCodingAgentCLI.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(help.contains("mcp <command>"))
        #expect(help.contains("builtin:<name>"))
        #expect(help.contains("built-in extensions"))
    }

    // pi-mono #9863: warnings from extension packages reach startup diagnostics.
    @Test func extensionPackageWarningsReachInteractiveAndPrintDiagnostics() {
        let warning = ResourceDiagnostic(type: "warning", message: "Extension package has no entry point", path: "/tmp/package")
        let loaded = LoadExtensionsResult(warnings: [warning])
        let diagnostics = extensionStartupDiagnostics(loaded)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message == warning.message)
        let interactive = startupDiagnosticDisposition(startup: [], runtime: diagnostics, isInteractive: true)
        #expect(interactive.diagnostics.first?.message == warning.message)
        #expect(!interactive.hasRuntimeErrors)
        let printMode = startupDiagnosticDisposition(startup: [], runtime: diagnostics, isInteractive: false)
        #expect(printMode.shouldPrint)
        #expect(printMode.diagnostics.first?.message == warning.message)
    }
}
