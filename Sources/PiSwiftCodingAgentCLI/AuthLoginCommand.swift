import ArgumentParser
import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

struct AuthLoginSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign in with an account in the browser, or save an API key, then exit",
        usage: "pi auth login <provider> [--api-key] [--no-browser]"
    )

    @Argument(help: "Provider name") var provider: String?
    @Argument(help: .hidden) var unexpected: [String] = []
    @Flag(name: .customLong("api-key"), help: "Save an API key instead of signing in with an account") var apiKey = false
    @Flag(name: .customLong("no-browser"), help: "Do not open a browser; use another sign-in method, e.g. device code") var noBrowser = false
    @Flag(name: .customLong("offline"), help: "Disable network refresh") var offline = false

    mutating func run() async throws {
        markCodingAgentEnvironment()
        guard unexpected.isEmpty else {
            fputs("Usage: pi auth login <provider> [--api-key] [--no-browser]\n", stderr)
            Darwin.exit(1)
        }
        let agentDir = getAgentDir()
        let settings = SettingsManager.create(FileManager.default.currentDirectoryPath, agentDir,
                                              projectTrusted: false)
        let storage = AuthStorage.create(getAuthPath())
        let registry = ModelRegistry(storage, agentDir,
                                     modelsStore: FileModelsStore((agentDir as NSString).appendingPathComponent("models-store.json")),
                                     networkEnabled: !offline && !CLIOptions.isOfflineEnvironmentEnabled())
        let result = await runAuthLogin(
            providerRef: provider, apiKey: apiKey, noBrowser: noBrowser,
            registry: registry, storage: storage, terminal: ProcessLoginTerminal(),
            getDeviceId: { settings.getOrCreateDeviceId() }
        )
        if result != 0 { Darwin.exit(result) }
    }
}

@MainActor
func runAuthLogin(
    providerRef: String?, apiKey: Bool, noBrowser: Bool,
    registry: ModelRegistry, storage: AuthStorage, terminal: any LoginTerminal,
    signal: CancellationToken = CancellationToken(),
    authPath: String = getAuthPath(),
    getDeviceId: (@Sendable () -> String)? = nil,
    localRefresh: (@Sendable () async -> ModelsRefreshResult)? = nil,
    catalogRefresh: (@Sendable (ModelsRefreshOptions) async -> ModelsRefreshResult)? = nil,
    apiKeyLogin: (@MainActor @Sendable (String, ProviderAuthInteraction) async throws -> Void)? = nil,
    loginProviders: [LoginProviderInfo]? = nil
) async -> Int32 {
    let usage = "pi auth login <provider> [--api-key] [--no-browser]"
    guard let providerRef, !providerRef.isEmpty else {
        terminal.error("Usage: \(usage)")
        return 1
    }
    if apiKey && noBrowser {
        terminal.error("--no-browser only applies to account sign-in; omit it with --api-key.")
        return 1
    }
    let providers = (loginProviders ?? registry.getLoginProviders()).filter { $0.id != "radius" }
    guard let provider = matchingLoginProvider(providerRef, in: providers) else {
        terminal.error("Unknown provider \"\(authSafeText(providerRef))\".")
        let loginIds = providers.filter { $0.oauth != nil || $0.apiKey?.login != nil }.map(\.id).sorted()
        terminal.error("Providers: \(loginIds.joined(separator: ", "))")
        return 1
    }
    guard terminal.interactive else {
        terminal.error("\"\(usage)\" requires an interactive terminal")
        return 1
    }

    let hasApiKeyLogin = provider.apiKey?.login != nil
    let accountLogin = !apiKey && provider.oauth != nil
    if !accountLogin && !hasApiKeyLogin {
        if apiKey && provider.oauth != nil {
            terminal.error("\(provider.name) has no API key login. Omit --api-key to sign in.")
        } else {
            terminal.error("\(provider.name) is configured outside pi (\(provider.apiKey?.name ?? "ambient credentials")).")
        }
        return 1
    }

    let secrets = AuthPromptSecrets()
    do {
        if accountLogin {
            guard let oauth = provider.oauth?.id else { return 1 }
            let callbacks = makeCLIAuthCallbacks(
                provider: provider, browser: !noBrowser, terminal: terminal, signal: signal,
                getDeviceId: getDeviceId
            )
            try await storage.login(oauth, callbacks: callbacks)
        } else {
            let interaction = ProviderAuthInteraction(
                prompt: { prompt in
                    if signal.isCancelled { throw LoginPromptError.cancelled }
                    switch prompt {
                    case .text(let message, let placeholder):
                        let suffix = placeholder.map { " (\($0))" } ?? ""
                        return try await terminal.question("\(message)\(suffix): ", signal: signal)
                    case .secret(let message, let placeholder):
                        let suffix = placeholder.map { " (\($0))" } ?? ""
                        let value = try await terminal.secret("\(message)\(suffix): ", signal: signal)
                        secrets.record(value)
                        return value
                    case .select(let prompt):
                        return try await selectAuthMethod(prompt, terminal: terminal, signal: signal)
                    }
                },
                notify: { event in
                    switch event {
                    case .info(let message, let links):
                        terminal.write(secrets.redact(message))
                        for link in links {
                            terminal.write(secrets.redact("  \(link.label.map { "\($0): " } ?? "")\(authDisplayURL(link.url))"))
                        }
                    case .progress(let message): terminal.write(secrets.redact(message))
                    }
                },
                signal: signal
            )
            if let apiKeyLogin { try await apiKeyLogin(provider.id, interaction) }
            else { try await registry.loginApiKey(provider.id, interaction: interaction) }
        }
    } catch {
        if error is CredentialSynchronizationError {
            terminal.error("Logged in to \(provider.name), but local model state could not be synchronized: \(secrets.redact(error.localizedDescription))")
        } else if signal.isCancelled || error is LoginPromptError || error is CancellationError || error is OAuthError && error.localizedDescription == "Login cancelled" {
            terminal.error("Login cancelled.")
        } else {
            terminal.error("Failed to log in to \(provider.name): \(secrets.redact(error.localizedDescription))")
        }
        return 1
    }

    if !storage.has(provider.id) {
        terminal.error("Failed to log in to \(provider.name): credentials could not be saved")
        return 1
    }
    let localResult: ModelsRefreshResult
    if let localRefresh { localResult = await localRefresh() }
    else { localResult = await registry.refresh(ModelsRefreshOptions(allowNetwork: false)) }
    if let failure = localResult.errors[provider.id] {
        terminal.error("Logged in to \(provider.name), but local model state could not be synchronized: \(secrets.redact(failure.localizedDescription))")
        return 1
    }
    terminal.write("\(accountLogin ? "Logged in to \(provider.name)" : "Saved API key for \(provider.name)"). Credentials saved to \(authPath)")

    let refreshToken = CancellationToken()
    let timeout = Task {
        try? await Task.sleep(for: .seconds(15))
        refreshToken.cancel()
    }
    let refreshOptions = ModelsRefreshOptions(providers: [provider.id], signal: refreshToken)
    let result: ModelsRefreshResult
    if let catalogRefresh { result = await catalogRefresh(refreshOptions) }
    else { result = await registry.refresh(refreshOptions) }
    timeout.cancel()
    if signal.isCancelled {
        terminal.write("Skipped the \(provider.name) model catalog refresh; pi refreshes it on next start.")
    } else if result.aborted {
        terminal.write("The \(provider.name) model catalog refresh timed out; pi refreshes it on next start.")
    } else if !result.errors.isEmpty {
        terminal.write("The \(provider.name) model catalog could not be refreshed; pi retries on next start.")
    }
    return 0
}

@MainActor
final class AuthPromptSecrets {
    private var values: [String] = []

    func record(_ value: String) {
        if !value.isEmpty { values.append(value) }
    }

    func redact(_ text: String) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }
}

func matchingLoginProvider(_ reference: String, in providers: [LoginProviderInfo]) -> LoginProviderInfo? {
    let key = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty else { return nil }
    return providers.first { $0.id.lowercased() == key || $0.name.lowercased() == key }
}

func authSafeText(_ value: String) -> String {
    String(value.unicodeScalars.map { scalar in
        scalar.value < 32 || scalar.value == 127 ? "�" : String(scalar)
    }.joined())
}

@MainActor
private func selectAuthMethod(
    _ prompt: OAuthSelectPrompt, terminal: any LoginTerminal, signal: CancellationToken
) async throws -> String {
    terminal.write(prompt.message)
    for (index, option) in prompt.options.enumerated() {
        terminal.write("  \(index + 1). \(option.label)\(option.description.map { " - \($0)" } ?? "")")
    }
    while true {
        let answer = try await terminal.question("Select 1-\(prompt.options.count): ", signal: signal).trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Int(answer), index > 0, index <= prompt.options.count {
            return prompt.options[index - 1].id
        }
        terminal.write("Enter a number from 1 to \(prompt.options.count).")
    }
}

@MainActor
func makeCLIAuthCallbacks(
    provider: LoginProviderInfo, browser: Bool, terminal: any LoginTerminal, signal: CancellationToken,
    getDeviceId: (@Sendable () -> String)? = nil
) -> OAuthLoginCallbacks {
    let noBrowserRerun = "\"pi auth login \(provider.id) --no-browser\""
    let selection = AuthMethodSelectionState()
    return OAuthLoginCallbacks(
        onAuth: { info in
            terminal.write("Open this URL to sign in:\n  \(authDisplayURL(info.url))")
            if let instructions = info.instructions { terminal.write(instructions) }
            if browser, let url = authWebURL(info.url) { terminal.openURL(url) }
            if selection.skipped.count == 1 {
                terminal.write("To use \"\(selection.skipped[0])\" instead, run \(noBrowserRerun)")
            } else if selection.skipped.count > 1 {
                let names = selection.skipped.map { "\"\($0)\"" }.joined(separator: ", ")
                terminal.write("Other sign-in methods: \(names). Run \(noBrowserRerun) to choose one.")
            }
        },
        onPrompt: { prompt in
            let suffix = prompt.placeholder.map { " (\($0))" } ?? ""
            return try await terminal.question("\(prompt.message)\(suffix): ", signal: signal)
        },
        onDeviceCode: { info in
            terminal.write("Open \(authDisplayURL(info.verificationUri)) and enter code: \(authSafeText(info.userCode))")
            if browser && info.openBrowserOnConfirm, let url = authWebURL(info.verificationUri) {
                terminal.openURL(url)
            }
            terminal.write("Waiting for authentication...")
        },
        onProgress: { terminal.write($0) },
        onManualCodeInput: {
            try await terminal.question("Paste redirect URL below, or complete login in browser: ", signal: signal)
        },
        signal: signal,
        getDeviceId: getDeviceId,
        onSelect: { prompt in
            if browser {
                guard let option = prompt.options.first else { throw LoginPromptError.cancelled }
                selection.skipped = Array(prompt.options.dropFirst()).map(\.label)
                return option.id
            }
            let otherOptions = Array(prompt.options.dropFirst())
            if otherOptions.isEmpty {
                guard let option = prompt.options.first else { throw LoginPromptError.cancelled }
                return option.id
            }
            if otherOptions.count == 1 {
                terminal.write("\(prompt.message) \(otherOptions[0].label)")
                return otherOptions[0].id
            }
            return try await selectAuthMethod(
                OAuthSelectPrompt(message: prompt.message, options: otherOptions),
                terminal: terminal, signal: signal
            )
        }
    )
}

@MainActor
private final class AuthMethodSelectionState {
    var skipped: [String] = []
}
