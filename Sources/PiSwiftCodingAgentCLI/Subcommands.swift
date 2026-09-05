import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

struct SessionSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        shouldDisplay: false
    )

    @OptionGroup var cli: CLIOptions

    mutating func run() async throws {
        try await PiCodingAgentCLI.runSession(cli)
    }
}

struct PackageSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Manage packages",
        helpNames: []
    )

    @OptionGroup var cli: CLIOptions

    @Flag(name: [.customShort("h"), .customLong("help")])
    var packageHelp = false

    mutating func run() async throws {
        markCodingAgentEnvironment()
        time("start")
        let arguments = cli.rawMessages + (packageHelp ? ["--help"] : [])
        let handled = await handlePackageCommand(
            arguments,
            approve: cli.approve,
            noApprove: cli.noApprove,
            noExtensions: cli.noExtensions,
            offline: cli.offline || CLIOptions.isOfflineEnvironmentEnabled()
        )
        if !handled {
            fputs("Unknown package command.\n", stderr)
            Darwin.exit(1)
        }
        if let exitCode = consumePackageCommandExitCode() {
            Darwin.exit(exitCode)
        }
    }
}

struct ConfigSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configure resources"
    )

    @OptionGroup var cli: CLIOptions

    mutating func run() async throws {
        markCodingAgentEnvironment()
        time("start")
        try await runConfigSubcommand(cli)
    }
}

private func runConfigSubcommand(_ cli: CLIOptions) async throws {
    let cwd = FileManager.default.currentDirectoryPath
    let agentDir = getAgentDir()
    let startupSettingsManager = SettingsManager.create(cwd, agentDir, projectTrusted: false)
    await runFirstTimeSetupIfNeeded(
        settingsManager: startupSettingsManager,
        isInteractive: true
    )
    let authStorage = AuthStorage.create(getAuthPath())
    let modelRegistry = ModelRegistry(authStorage, agentDir)
    let trustChoice = projectTrustChoice(approve: cli.approve, noApprove: cli.noApprove)
    let trustContext = await resolveProjectTrustForCLI(
        cwd: cwd,
        agentDir: agentDir,
        modelRegistry: modelRegistry,
        eventBus: createEventBus(),
        choice: trustChoice,
        persistChoice: trustChoice != nil,
        noExtensions: cli.noExtensions,
        mode: .tui,
        hasUI: true
    )
    let settingsManager = trustContext.settingsManager
    reportSubcommandSettingsErrors(settingsManager, context: "config command")
    let packageManager = DefaultPackageManager(
        cwd: cwd,
        agentDir: agentDir,
        settingsManager: settingsManager,
        projectTrusted: trustContext.trust.trusted,
        offline: cli.offline || CLIOptions.isOfflineEnvironmentEnabled()
    )
    let resolvedPaths = try await packageManager.resolve()
    await selectConfig(
        resolvedPaths: resolvedPaths,
        settingsManager: settingsManager,
        cwd: cwd,
        agentDir: agentDir,
        initialProjectMode: cli.configLocal,
        projectTrusted: trustContext.trust.trusted
    )
}

private func reportSubcommandSettingsErrors(_ settingsManager: SettingsManager, context: String) {
    reportStartupDiagnostics(collectSettingsDiagnostics(settingsManager))
}

struct AuthSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Check or export authentication credentials",
        subcommands: [
            AuthCheckSubcommand.self,
            PrintAPIKeySubcommand.self,
            PrintBearerTokenSubcommand.self,
        ]
    )

    @Option(help: "Provider name")
    var provider: String?

    @Option(help: "Model ID")
    var model: String?
}

struct AuthCheckSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check provider authentication",
        usage: "\(APP_NAME) auth check (--provider <provider> | --model <model>) [--credentials]"
    )

    @ParentCommand var parent: AuthSubcommand

    @Flag(
        name: [.customLong("credentials"), .customLong("show-credential")],
        help: "Include the resolved credential in output"
    )
    var showCredential = false

    mutating func run() async throws {
        markCodingAgentEnvironment()
        let context = makeAuthCommandContext(provider: parent.provider, model: parent.model)
        let result = await runAuthCheck(
            provider: context.provider,
            model: context.model,
            showCredential: showCredential,
            registry: context.registry,
            authStorage: context.authStorage
        )
        finishSubcommand(result)
    }
}

struct PrintAPIKeySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "print-api-key",
        abstract: "Print an API key",
        usage: "\(APP_NAME) auth print-api-key (--provider <provider> | --model <model>)"
    )

    @ParentCommand var parent: AuthSubcommand

    mutating func run() async throws {
        markCodingAgentEnvironment()
        let context = makeAuthCommandContext(provider: parent.provider, model: parent.model)
        let result = await runCredentialPrint(
            kind: .apiKey,
            provider: context.provider,
            model: context.model,
            minimumOAuthValidityMs: defaultOAuthMinimumValidityMs,
            registry: context.registry,
            authStorage: context.authStorage
        )
        finishSubcommand(result)
    }
}

struct PrintBearerTokenSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "print-bearer-token",
        abstract: "Print an OAuth bearer token",
        usage: "\(APP_NAME) auth print-bearer-token (--provider <provider> | --model <model>) [--min-expiry <duration>]"
    )

    @ParentCommand var parent: AuthSubcommand

    @Option(
        name: [.customLong("min-expiry"), .customLong("minimum-validity-ms")],
        help: "Required token validity, for example 300000ms, 30m, or 1h"
    )
    var minimumValidity: OAuthValidityDuration?

    mutating func run() async throws {
        markCodingAgentEnvironment()
        let context = makeAuthCommandContext(provider: parent.provider, model: parent.model)
        let result = await runCredentialPrint(
            kind: .bearerToken,
            provider: context.provider,
            model: context.model,
            minimumOAuthValidityMs: minimumValidity?.milliseconds ?? defaultOAuthMinimumValidityMs,
            registry: context.registry,
            authStorage: context.authStorage
        )
        finishSubcommand(result)
    }
}

struct UpdateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update Pi resources"
    )

    @Flag(help: "Refresh model catalogs")
    var models = false

    mutating func run() async throws {
        markCodingAgentEnvironment()
        guard models else {
            finishSubcommand(CLICommandResult.failure("Specify --models to refresh model catalogs."))
            return
        }

        let agentDir = getAgentDir()
        let authStorage = AuthStorage.create(getAuthPath())
        // ModelRegistry does not perform a network refresh during initialization.
        // Its networkEnabled=false setting also disables explicit refresh calls, so
        // this command enables only the forced refresh that follows.
        let registry = ModelRegistry(authStorage, agentDir)
        let result = await runModelsUpdate { options in
            await registry.refresh(options)
        }
        finishSubcommand(result)
    }
}

struct CLICommandResult: Sendable {
    var stdout: String?
    var stderr: String?
    var exitCode: Int32

    static func success(_ stdout: String) -> CLICommandResult {
        CLICommandResult(stdout: stdout, stderr: nil, exitCode: 0)
    }

    static func failure(_ stderr: String) -> CLICommandResult {
        CLICommandResult(stdout: nil, stderr: stderr, exitCode: 1)
    }
}

enum CredentialPrintKind: Sendable {
    case apiKey
    case bearerToken
}

struct OAuthValidityDuration: ExpressibleByArgument, Sendable {
    var milliseconds: Double

    init(milliseconds: Double) {
        self.milliseconds = milliseconds
    }

    init?(argument: String) {
        let pattern = #"^(\d+)(ms|s|m|h)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: argument,
                range: NSRange(argument.startIndex..., in: argument)
              ),
              let amountRange = Range(match.range(at: 1), in: argument),
              let amount = Double(argument[amountRange]) else {
            return nil
        }

        let unit: String
        if let unitRange = Range(match.range(at: 2), in: argument) {
            unit = String(argument[unitRange])
        } else {
            unit = "ms"
        }
        let multiplier: Double
        switch unit {
        case "ms": multiplier = 1
        case "s": multiplier = 1_000
        case "m": multiplier = 60_000
        case "h": multiplier = 3_600_000
        default: return nil
        }
        milliseconds = amount * multiplier
    }
}

private struct AuthCommandContext {
    var provider: String?
    var model: String?
    var registry: ModelRegistry
    var authStorage: AuthStorage
}

private func makeAuthCommandContext(provider: String?, model: String?) -> AuthCommandContext {
    let agentDir = getAgentDir()
    let authStorage = AuthStorage.create(getAuthPath())
    let registry = ModelRegistry(
        authStorage,
        agentDir,
        modelsStore: InMemoryModelsStore(),
        networkEnabled: false
    )
    return AuthCommandContext(
        provider: provider,
        model: model,
        registry: registry,
        authStorage: authStorage
    )
}

private func finishSubcommand(_ result: CLICommandResult) {
    if let output = result.stdout {
        fputs("\(output)\n", stdout)
    }
    if let diagnostic = result.stderr {
        fputs("Error: \(diagnostic)\n", stderr)
    }
    if result.exitCode != 0 {
        Darwin.exit(result.exitCode)
    }
}

func runAuthCheck(
    provider cliProvider: String?,
    model cliModel: String?,
    showCredential: Bool,
    registry: ModelRegistry,
    authStorage: AuthStorage
) async -> CLICommandResult {
    switch resolveAuthProvider(provider: cliProvider, model: cliModel, registry: registry) {
    case .failure(let message):
        return .failure(message)
    case .success(let provider):
        guard knownProvider(provider, registry: registry) else {
            return .failure("Unknown provider \"\(provider)\". Use --list-models to see available providers.")
        }
        guard let source = credentialSource(provider: provider, authStorage: authStorage) else {
            return .failure("Authentication is not configured for \(provider).")
        }
        guard let credential = await authStorage.getApiKey(
            provider,
            minimumOAuthValidityMs: defaultOAuthMinimumValidityMs
        ), !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Authentication for \(provider) is configured but is not usable.")
        }
        if case .oauth(let oauth) = authStorage.get(provider),
           !oauthMeetsMinimumValidity(oauth, minimumValidityMs: defaultOAuthMinimumValidityMs) {
            return .failure("OAuth credential for \(provider) could not meet the minimum validity requirement.")
        }

        let type = source.authType == .oauth ? "OAuth" : "API key"
        var output = "Authentication for \(provider) is usable (\(type), \(source.description))."
        if showCredential {
            output += "\n\(credential)"
        }
        return .success(output)
    }
}

func runCredentialPrint(
    kind: CredentialPrintKind,
    provider cliProvider: String?,
    model cliModel: String?,
    minimumOAuthValidityMs: Double = defaultOAuthMinimumValidityMs,
    registry: ModelRegistry,
    authStorage: AuthStorage
) async -> CLICommandResult {
    switch resolveAuthProvider(provider: cliProvider, model: cliModel, registry: registry) {
    case .failure(let message):
        return .failure(message)
    case .success(let provider):
        guard knownProvider(provider, registry: registry) else {
            return .failure("Unknown provider \"\(provider)\". Use --list-models to see available providers.")
        }

        switch kind {
        case .apiKey:
            if case .oauth? = authStorage.get(provider) {
                return .failure("Provider \"\(provider)\" is configured with OAuth, not an API key.")
            }
            guard let credential = await authStorage.getApiKey(provider),
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("No usable API key is configured for \(provider).")
            }
            return .success(credential)

        case .bearerToken:
            guard case .oauth? = authStorage.get(provider) else {
                return .failure("Provider \"\(provider)\" is not configured with an OAuth bearer token.")
            }
            let requiredValidity = max(defaultOAuthMinimumValidityMs, minimumOAuthValidityMs)
            guard await authStorage.getApiKey(
                provider,
                minimumOAuthValidityMs: requiredValidity
            ) != nil,
            case .oauth(let refreshed) = authStorage.get(provider),
            oauthMeetsMinimumValidity(refreshed, minimumValidityMs: requiredValidity),
            !refreshed.access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(
                    "OAuth credential for \(provider) could not be refreshed to meet the minimum validity requirement."
                )
            }
            return .success(refreshed.access)
        }
    }
}

func runModelsUpdate(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    refresh: @escaping @Sendable (ModelsRefreshOptions) async -> ModelsRefreshResult
) async -> CLICommandResult {
    let signal = CancellationToken()
    let timeout = Task {
        do {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            signal.cancel()
        } catch {
            // The refresh completed before the timeout.
        }
    }
    defer { timeout.cancel() }

    let result = await refresh(ModelsRefreshOptions(
        allowNetwork: true,
        providers: nil,
        force: true,
        signal: signal
    ))
    if result.aborted {
        return .failure("Model catalog refresh timed out after 15 seconds.")
    }
    if !result.errors.isEmpty {
        let details = result.errors
            .map { provider, error in "\(provider): \(error.localizedDescription)" }
            .sorted()
            .joined(separator: "; ")
        return .failure("Could not refresh model catalogs: \(details)")
    }
    return .success("Model catalogs refreshed.")
}

private enum AuthProviderResolution {
    case success(String)
    case failure(String)
}

private func resolveAuthProvider(
    provider cliProvider: String?,
    model cliModel: String?,
    registry: ModelRegistry
) -> AuthProviderResolution {
    let provider = cliProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = cliModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard provider?.isEmpty == false || model?.isEmpty == false else {
        return .failure("Specify --provider <provider> or --model <model>.")
    }
    guard let model, !model.isEmpty else {
        let requested = provider ?? ""
        let canonical = registry.getAll().first {
            $0.provider.caseInsensitiveCompare(requested) == .orderedSame
        }?.provider
        return .success(canonical ?? requested)
    }

    let resolved = resolveCliModel(
        cliProvider: provider,
        cliModel: model,
        modelRegistry: registry
    )
    if let error = resolved.error {
        return .failure(error)
    }
    guard let resolvedModel = resolved.model else {
        return .failure("Unable to resolve model \"\(model)\".")
    }
    return .success(resolvedModel.provider)
}

private func knownProvider(_ provider: String, registry: ModelRegistry) -> Bool {
    registry.getAll().contains { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
}

private enum AuthType {
    case apiKey
    case oauth
}

private struct CredentialSource {
    var authType: AuthType
    var description: String
}

private func credentialSource(provider: String, authStorage: AuthStorage) -> CredentialSource? {
    switch authStorage.get(provider) {
    case .apiKey?:
        return CredentialSource(authType: .apiKey, description: "auth.json")
    case .oauth?:
        return CredentialSource(authType: .oauth, description: "OAuth in auth.json")
    case nil:
        if let names = findEnvKeys(provider: provider) {
            return CredentialSource(
                authType: .apiKey,
                description: "environment variable \(names.joined(separator: ", "))"
            )
        }
        return nil
    }
}

private func oauthMeetsMinimumValidity(
    _ credential: OAuthCredential,
    minimumValidityMs: Double,
    now: Double = Date().timeIntervalSince1970 * 1_000
) -> Bool {
    guard let expires = credential.expires else { return false }
    return now + max(defaultOAuthMinimumValidityMs, minimumValidityMs) < expires
}
