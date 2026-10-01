import PiSwiftCodingAgent

func extensionStartupDiagnostics(_ result: LoadExtensionsResult, inline: Bool = false) -> [ResourceDiagnostic] {
    result.warnings + result.errors.map {
        ResourceDiagnostic(type: "error", message: "Failed to load \(inline ? "inline extension" : "extension"): \($0.localizedDescription)")
    }
}

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
