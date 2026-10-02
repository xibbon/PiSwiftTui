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
    isInteractive: Bool,
    resources: [ResourceDiagnostic] = [],
    resourcesShown: Bool = false
) -> StartupDiagnosticDisposition {
    let hasRuntimeErrors = runtime.contains { $0.type == "error" }
    let diagnostics = deduplicateDiagnostics(startup + runtime)
    let chatDiagnostics = isInteractive && resourcesShown && !hasRuntimeErrors
        ? diagnostics.filter { diagnostic in
            !resources.contains {
                $0.type == diagnostic.type && $0.message == diagnostic.message && $0.path == diagnostic.path
            }
        }
        : diagnostics
    return StartupDiagnosticDisposition(
        diagnostics: chatDiagnostics,
        hasRuntimeErrors: hasRuntimeErrors,
        shouldPrint: !isInteractive || hasRuntimeErrors
    )
}
