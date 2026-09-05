import PiSwiftCodingAgent

struct StartupDiagnosticDisposition: Sendable {
    var diagnostics: [ResourceDiagnostic]
    var hasRuntimeErrors: Bool
    var shouldPrint: Bool
}

func startupDiagnosticDisposition(
    startup: [ResourceDiagnostic],
    runtime: [ResourceDiagnostic],
    isInteractive: Bool
) -> StartupDiagnosticDisposition {
    let hasRuntimeErrors = runtime.contains { $0.type == "error" }
    return StartupDiagnosticDisposition(
        diagnostics: deduplicateDiagnostics(startup + runtime),
        hasRuntimeErrors: hasRuntimeErrors,
        shouldPrint: !isInteractive || hasRuntimeErrors
    )
}
