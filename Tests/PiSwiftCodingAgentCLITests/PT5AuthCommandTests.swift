import Darwin
import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI
import Testing

@MainActor
private final class ScriptedLoginTerminal: LoginTerminal, AuthOutput {
    var interactive = true
    var answers: [String] = []
    var lines: [String] = []
    var errors: [String] = []
    var questions: [String] = []
    var opened: [String] = []

    init(_ answers: [String] = []) { self.answers = answers }
    func write(_ line: String) { lines.append(line) }
    func error(_ line: String) { errors.append(line) }
    func question(_ message: String, signal: CancellationToken) async throws -> String {
        questions.append(message)
        if signal.isCancelled || answers.isEmpty { throw LoginPromptError.cancelled }
        return answers.removeFirst()
    }
    func secret(_ message: String, signal: CancellationToken) async throws -> String {
        try await question(message, signal: signal)
    }
    func openURL(_ url: String) { opened.append(url) }
}

private func testAuthRegistry(_ storage: AuthStorage) -> ModelRegistry {
    ModelRegistry(storage, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
}

@Test func pt5AuthParserKeepsUnexpectedKeyOutOfParserError() throws {
    let parsed = try #require(PiCodingAgentCLI.parseAsRoot(["auth", "login", "groq", "--api-key", "test-key"])
        as? AuthLoginSubcommand)
    #expect(parsed.unexpected == ["test-key"])
}

private enum PT5AuthTestError: Error, LocalizedError {
    case snapshot
    case echoedKey(String)
    case storage
    var errorDescription: String? {
        switch self {
        case .snapshot: "snapshot failed"
        case .echoedKey(let key): "provider rejected \(key)"
        case .storage: "backend write failed"
        }
    }
}

private final class PT5FailingAuthBackend: AuthStorageBackend {
    private let initial = #"{"groq":{"type":"api_key","key":"stored"}}"#

    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        let transaction = try body(initial)
        if transaction.next != nil { throw PT5AuthTestError.storage }
        transaction.onCommit()
        return transaction.result
    }

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        let transaction = try await body(initial)
        if transaction.next != nil { throw PT5AuthTestError.storage }
        transaction.onCommit()
        return transaction.result
    }
}

@Test @MainActor func pt5AuthLoginRequiresProviderAndListsKnownProviders() async {
    let storage = AuthStorage.inMemory()
    let registry = testAuthRegistry(storage)
    let terminal = ScriptedLoginTerminal()
    #expect(await runAuthLogin(providerRef: nil, apiKey: false, noBrowser: false,
                               registry: registry, storage: storage, terminal: terminal) == 1)
    #expect(terminal.errors == ["Usage: pi auth login <provider> [--api-key] [--no-browser]"])
    terminal.errors = []
    #expect(await runAuthLogin(providerRef: "nope", apiKey: false, noBrowser: false,
                               registry: registry, storage: storage, terminal: terminal) == 1)
    #expect(terminal.errors.first == "Unknown provider \"nope\".")
    #expect(terminal.errors.last?.contains("openai") == true)
    #expect(terminal.errors.last?.contains("radius") == false)
}

@Test func pt5AuthLoginParserRejectsUnknownOption() throws {
    #expect(throws: Error.self) {
        _ = try PiCodingAgentCLI.parseAsRoot(PiCodingAgentCLI.preprocessArguments(
            ["auth", "login", "groq", "--bogus"]
        ))
    }
}

@Test @MainActor func pt5AuthLoginRejectsIncompatibleFlagsAndNonterminal() async {
    let storage = AuthStorage.inMemory()
    let registry = testAuthRegistry(storage)
    let terminal = ScriptedLoginTerminal()
    #expect(await runAuthLogin(providerRef: "groq", apiKey: true, noBrowser: true,
                               registry: registry, storage: storage, terminal: terminal) == 1)
    #expect(terminal.errors == ["--no-browser only applies to account sign-in; omit it with --api-key."])
    terminal.errors = []
    terminal.interactive = false
    #expect(await runAuthLogin(providerRef: "groq", apiKey: false, noBrowser: false,
                               registry: registry, storage: storage, terminal: terminal) == 1)
    #expect(terminal.errors == ["\"pi auth login <provider> [--api-key] [--no-browser]\" requires an interactive terminal"])
}

@Test @MainActor func pt5AuthLoginSavesPromptedApiKeyWithoutOutputLeak() async {
    let secret = "pt5-very-secret"
    let storage = AuthStorage.inMemory()
    let registry = testAuthRegistry(storage)
    let terminal = ScriptedLoginTerminal([secret])
    #expect(await runAuthLogin(providerRef: "groq", apiKey: true, noBrowser: false,
                               registry: registry, storage: storage, terminal: terminal,
                               authPath: "/test/auth.json") == 0)
    guard case .apiKey(let saved)? = storage.get("groq") else {
        Issue.record("API key was not stored")
        return
    }
    #expect(saved.key == secret)
    #expect(terminal.questions == ["Enter Groq API key: "])
    #expect(terminal.lines.contains("Saved API key for Groq. Credentials saved to /test/auth.json"))
    #expect(!terminal.lines.joined().contains(secret))
    #expect(!terminal.errors.joined().contains(secret))
}

@Test @MainActor func pt5AuthLoginRedactsSecretFromProviderError() async {
    let secret = "pt5-secret-provider-error"
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal([secret])
    #expect(await runAuthLogin(providerRef: "groq", apiKey: true, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal,
                               apiKeyLogin: { _, interaction in
                                   let value = try await interaction.prompt(.secret(message: "Enter key"))
                                   throw PT5AuthTestError.echoedKey(value)
                               }) == 1)
    #expect(!storage.has("groq"))
    #expect(terminal.errors == ["Failed to log in to Groq: provider rejected [REDACTED]"])
    #expect(!terminal.lines.joined().contains(secret))
}

@Test @MainActor func pt5AuthLoginUsesApiKeyForProviderWithoutAccountLogin() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal(["key"])
    #expect(await runAuthLogin(providerRef: "Groq", apiKey: false, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal) == 0)
    #expect(storage.has("groq"))
    #expect(terminal.questions == ["Enter Groq API key: "])
}

@Test @MainActor func pt5AuthLoginCancellationKeepsStoreEmpty() async {
    let storage = AuthStorage.inMemory()
    let token = CancellationToken()
    token.cancel()
    let terminal = ScriptedLoginTerminal()
    #expect(await runAuthLogin(providerRef: "groq", apiKey: false, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage,
                               terminal: terminal, signal: token) == 1)
    #expect(terminal.errors == ["Login cancelled."])
    #expect(!storage.has("groq"))
}

@Test @MainActor func pt5AuthLogoutRemovesCredentialAndCanRepeat() async {
    let storage = AuthStorage.inMemory([
        "groq": .apiKey(ApiKeyCredential(key: "secret")),
        "openai": .apiKey(ApiKeyCredential(key: "other")),
    ])
    let registry = testAuthRegistry(storage)
    let output = ScriptedLoginTerminal()
    #expect(await runAuthLogout(providerRef: "Groq", registry: registry, storage: storage, output: output) == 0)
    #expect(!storage.has("groq"))
    #expect(storage.has("openai"))
    #expect(output.lines == ["Removed stored API key for Groq. Environment variables and models.json config are unchanged."])
    output.lines = []
    #expect(await runAuthLogout(providerRef: "groq", registry: registry, storage: storage, output: output) == 0)
    #expect(output.lines == ["No stored credentials for Groq. Environment variables and models.json config are unchanged."])
}

@Test @MainActor func pt5AuthLogoutReportsStorageFailure() async {
    let storage = AuthStorage(storage: PT5FailingAuthBackend())
    let output = ScriptedLoginTerminal()
    #expect(storage.has("groq"))
    #expect(await runAuthLogout(providerRef: "groq", registry: testAuthRegistry(storage),
                                storage: storage, output: output) == 1)
    #expect(storage.has("groq"))
    #expect(output.errors == ["Logout failed: backend write failed"])
}

@Test @MainActor func pt5AuthLogoutUnknownAndUnloadedProvider() async {
    let storage = AuthStorage.inMemory(["unloaded": .apiKey(ApiKeyCredential(key: "secret"))])
    let registry = testAuthRegistry(storage)
    let output = ScriptedLoginTerminal()
    #expect(await runAuthLogout(providerRef: "nope", registry: registry, storage: storage, output: output) == 1)
    #expect(output.errors == ["Unknown provider \"nope\".", "Stored credentials: unloaded"])
    #expect(await runAuthLogout(providerRef: "unloaded", registry: registry, storage: storage, output: output) == 0)
    #expect(!storage.has("unloaded"))
}

@Test @MainActor func pt5AuthURLDisplayRemovesTerminalControls() {
    #expect(authDisplayURL("file:///bad\u{1B}[31m") == "file:///bad�[31m")
    #expect(authWebURL("file:///bad") == nil)
    #expect(authWebURL("https://example.test/path") == "https://example.test/path")
}

@Test @MainActor func pt5AuthDeviceCodeHonorsBrowserFlag() async {
    let terminal = ScriptedLoginTerminal()
    let provider = LoginProviderInfo(id: "github-copilot", name: "GitHub Copilot")
    let token = CancellationToken()
    let permitted = makeCLIAuthCallbacks(provider: provider, browser: true, terminal: terminal, signal: token)
    permitted.onDeviceCode?(OAuthDeviceCodeInfo(userCode: "ABCD-1234", verificationUri: "https://example.test/device"))
    #expect(terminal.lines.contains("Open https://example.test/device and enter code: ABCD-1234"))
    #expect(terminal.opened == ["https://example.test/device"])
    terminal.opened = []
    let denied = makeCLIAuthCallbacks(provider: provider, browser: true, terminal: terminal, signal: token)
    denied.onDeviceCode?(OAuthDeviceCodeInfo(userCode: "ABCD-1234", verificationUri: "https://example.test/device", openBrowserOnConfirm: false))
    #expect(terminal.opened.isEmpty)
    let noBrowser = makeCLIAuthCallbacks(provider: provider, browser: false, terminal: terminal, signal: token)
    noBrowser.onDeviceCode?(OAuthDeviceCodeInfo(userCode: "ABCD-1234", verificationUri: "https://example.test/device"))
    #expect(terminal.opened.isEmpty)
}

@Test @MainActor func pt5AuthAccountMethodChoiceAndBrowserHint() async throws {
    let terminal = ScriptedLoginTerminal()
    let callbacks = makeCLIAuthCallbacks(
        provider: LoginProviderInfo(id: "test-provider", name: "Test Provider"),
        browser: true, terminal: terminal, signal: CancellationToken()
    )
    let choice = OAuthSelectPrompt(message: "Sign in:", options: [
        OAuthSelectOption(id: "browser", label: "Browser"),
        OAuthSelectOption(id: "device", label: "Device code"),
        OAuthSelectOption(id: "copy", label: "Copy code"),
    ])
    #expect(try await callbacks.onSelect?(choice) == "browser")
    callbacks.onAuth(OAuthAuthInfo(url: "https://example.test/auth", instructions: "Finish in the browser"))
    #expect(terminal.questions.isEmpty)
    #expect(terminal.opened == ["https://example.test/auth"])
    #expect(terminal.lines.contains("Open this URL to sign in:\n  https://example.test/auth"))
    #expect(terminal.lines.contains("Other sign-in methods: \"Device code\", \"Copy code\". Run \"pi auth login test-provider --no-browser\" to choose one."))
}

@Test @MainActor func pt5AuthBrowserEventWithoutMethodChoiceHasNoHint() {
    let terminal = ScriptedLoginTerminal()
    let callbacks = makeCLIAuthCallbacks(
        provider: LoginProviderInfo(id: "test-provider", name: "Test Provider"),
        browser: true, terminal: terminal, signal: CancellationToken()
    )
    callbacks.onAuth(OAuthAuthInfo(url: "https://example.test/auth"))
    #expect(terminal.opened == ["https://example.test/auth"])
    #expect(!terminal.lines.joined().contains("--no-browser"))
}

@Test @MainActor func pt5AuthApiKeySetupAsksForSelection() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal(["2"])
    #expect(await runAuthLogin(providerRef: "groq", apiKey: true, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal,
                               apiKeyLogin: { providerId, interaction in
                                   let choice = try await interaction.prompt(.select(OAuthSelectPrompt(
                                       message: "Choose credentials:", options: [
                                           OAuthSelectOption(id: "first", label: "First"),
                                           OAuthSelectOption(id: "second", label: "Second", description: "Other credentials"),
                                       ]
                                   )))
                                   storage.set(providerId, credential: .apiKey(ApiKeyCredential(key: choice)))
                               }) == 0)
    guard case .apiKey(let saved)? = storage.get("groq") else {
        Issue.record("Selected key was not stored")
        return
    }
    #expect(saved.key == "second")
    #expect(terminal.questions == ["Select 1-2: "])
    #expect(terminal.lines.contains("  2. Second - Other credentials"))
}

@Test @MainActor func pt5AuthProviderConfiguredOutsidePi() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal()
    let provider = LoginProviderInfo(
        id: "outside", name: "Outside",
        apiKey: ApiKeyAuthMethod(name: "AWS profile", envVars: [], login: nil)
    )
    #expect(await runAuthLogin(providerRef: "outside", apiKey: false, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage,
                               terminal: terminal, loginProviders: [provider]) == 1)
    #expect(terminal.errors == ["Outside is configured outside pi (AWS profile)."])
}

@Test @MainActor func pt5AuthNoBrowserSelectsOtherMethodWithoutOpening() async throws {
    let terminal = ScriptedLoginTerminal()
    let callbacks = makeCLIAuthCallbacks(
        provider: LoginProviderInfo(id: "test-provider", name: "Test Provider"),
        browser: false, terminal: terminal, signal: CancellationToken()
    )
    let choice = OAuthSelectPrompt(message: "Sign in:", options: [
        OAuthSelectOption(id: "browser", label: "Browser"),
        OAuthSelectOption(id: "device", label: "Device code"),
    ])
    #expect(try await callbacks.onSelect?(choice) == "device")
    #expect(terminal.lines == ["Sign in: Device code"])
    callbacks.onAuth(OAuthAuthInfo(url: "https://example.test/auth"))
    #expect(terminal.opened.isEmpty)
    #expect(!terminal.lines.joined().contains("--no-browser"))
}

@Test @MainActor func pt5AuthNoBrowserReasksInvalidMethodAndKeepsOnlyMethod() async throws {
    let terminal = ScriptedLoginTerminal(["7", "2"])
    let callbacks = makeCLIAuthCallbacks(
        provider: LoginProviderInfo(id: "test-provider", name: "Test Provider"),
        browser: false, terminal: terminal, signal: CancellationToken()
    )
    let many = OAuthSelectPrompt(message: "Sign in:", options: [
        OAuthSelectOption(id: "browser", label: "Browser"),
        OAuthSelectOption(id: "device", label: "Device code"),
        OAuthSelectOption(id: "copy", label: "Copy code"),
    ])
    #expect(try await callbacks.onSelect?(many) == "copy")
    #expect(terminal.lines.prefix(3) == ["Sign in:", "  1. Device code", "  2. Copy code"])
    #expect(terminal.lines.contains("Enter a number from 1 to 2."))
    let only = OAuthSelectPrompt(message: "Sign in:", options: [OAuthSelectOption(id: "browser", label: "Browser")])
    #expect(try await callbacks.onSelect?(only) == "browser")
    callbacks.onAuth(OAuthAuthInfo(url: "https://example.test/auth"))
    #expect(terminal.opened.isEmpty)
}

@Test @MainActor func pt5AuthOnlyOAuthRejectsApiKeyFlag() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal()
    #expect(await runAuthLogin(providerRef: "openai-codex", apiKey: true, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal) == 1)
    #expect(terminal.errors == ["OpenAI Codex has no API key login. Omit --api-key to sign in."])
}

@Test @MainActor func pt5AuthLoginReportsCommittedCredentialSeparately() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal(["key"])
    #expect(await runAuthLogin(providerRef: "groq", apiKey: true, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal,
                               localRefresh: {
                                   ModelsRefreshResult(aborted: false, errors: ["groq": PT5AuthTestError.snapshot])
                               }) == 1)
    #expect(storage.has("groq"))
    #expect(terminal.errors.first?.hasPrefix("Logged in to Groq, but local model state could not be synchronized:") == true)
}

@Test @MainActor func pt5AuthLogoutReportsCommittedRemovalSeparately() async {
    let storage = AuthStorage.inMemory(["groq": .apiKey(ApiKeyCredential(key: "key"))])
    let output = ScriptedLoginTerminal()
    #expect(await runAuthLogout(providerRef: "groq", registry: testAuthRegistry(storage), storage: storage,
                                output: output, localRefresh: {
                                    ModelsRefreshResult(aborted: false, errors: ["groq": PT5AuthTestError.snapshot])
                                }) == 1)
    #expect(!storage.has("groq"))
    #expect(output.errors.first?.hasPrefix("Credentials removed for Groq, but local model state could not be synchronized:") == true)
}

@Test @MainActor func pt5AuthLoginRefreshCancellationKeepsCredential() async {
    let storage = AuthStorage.inMemory()
    let terminal = ScriptedLoginTerminal(["key"])
    let signal = CancellationToken()
    #expect(await runAuthLogin(providerRef: "groq", apiKey: false, noBrowser: false,
                               registry: testAuthRegistry(storage), storage: storage, terminal: terminal,
                               signal: signal, catalogRefresh: { _ in
                                   signal.cancel()
                                   return ModelsRefreshResult(aborted: true)
                               }) == 0)
    #expect(storage.has("groq"))
    #expect(terminal.lines.contains("Skipped the Groq model catalog refresh; pi refreshes it on next start."))
}

@Test @MainActor func pt5AuthLogoutRemovesStoredAccountCredential() async {
    let oauth = OAuthCredential(access: "access", refresh: "refresh", expires: Date().timeIntervalSince1970 * 1_000 + 10_000)
    let storage = AuthStorage.inMemory(["openai-codex": .oauth(oauth)])
    let output = ScriptedLoginTerminal()
    #expect(await runAuthLogout(providerRef: "OpenAI Codex", registry: testAuthRegistry(storage),
                                storage: storage, output: output) == 0)
    #expect(!storage.has("openai-codex"))
    #expect(output.lines == ["Logged out of OpenAI Codex."])
}

@Test func pt5LinePromptStopsAtEOFAndAbort() async throws {
    var input: [Int32] = [0, 0]
    var output: [Int32] = [0, 0]
    #expect(pipe(&input) == 0)
    #expect(pipe(&output) == 0)
    defer {
        close(input[0]); close(input[1]); close(output[0]); close(output[1])
    }
    let token = CancellationToken()
    close(input[1])
    input[1] = -1
    #expect(throws: LoginPromptError.self) {
        try readAuthLine("Code: ", inputFD: input[0], outputFD: output[1], signal: token, masked: false)
    }

    var pending: [Int32] = [0, 0]
    #expect(pipe(&pending) == 0)
    defer { close(pending[0]); close(pending[1]) }
    let abort = CancellationToken()
    let pendingReadFD = pending[0]
    let outputWriteFD = output[1]
    let task = Task.detached {
        try readAuthLine("Code: ", inputFD: pendingReadFD, outputFD: outputWriteFD, signal: abort, masked: false)
    }
    abort.cancel()
    do {
        _ = try await task.value
        Issue.record("Aborted line prompt returned a value")
    } catch is LoginPromptError {
        // Expected: the poll loop checks cancellation without waiting for EOF.
    }
}

@Test func pt5LinePromptReturnsAtNewlineBeforeEOF() throws {
    var input: [Int32] = [0, 0]
    var output: [Int32] = [0, 0]
    #expect(pipe(&input) == 0)
    #expect(pipe(&output) == 0)
    defer {
        close(input[0]); close(input[1]); close(output[0]); close(output[1])
    }
    let answer = Array("first\nsecond".utf8)
    _ = answer.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
    #expect(try readAuthLine("Code: ", inputFD: input[0], outputFD: output[1],
                             signal: CancellationToken(), masked: false) == "first")
}

@Test func pt5LinePromptHandlesCtrlCAndAlreadyCancelled() throws {
    var input: [Int32] = [0, 0]
    var output: [Int32] = [0, 0]
    #expect(pipe(&input) == 0)
    #expect(pipe(&output) == 0)
    defer {
        close(input[0]); close(input[1]); close(output[0]); close(output[1])
    }
    var interrupt: UInt8 = 3
    _ = Darwin.write(input[1], &interrupt, 1)
    #expect(throws: LoginPromptError.self) {
        try readAuthLine("Code: ", inputFD: input[0], outputFD: output[1],
                         signal: CancellationToken(), masked: false)
    }
    let cancelled = CancellationToken()
    cancelled.cancel()
    #expect(throws: LoginPromptError.self) {
        try readAuthLine("Code: ", inputFD: input[0], outputFD: output[1],
                         signal: cancelled, masked: false)
    }
}

@Test @MainActor func pt5CancelledManualCodePromptDoesNotCancelLogin() async {
    var input: [Int32] = [0, 0]
    var output: [Int32] = [0, 0]
    #expect(pipe(&input) == 0)
    #expect(pipe(&output) == 0)
    defer {
        close(input[0]); close(input[1]); close(output[0]); close(output[1])
    }
    let token = CancellationToken()
    let terminal = ProcessLoginTerminal(inputFD: input[0], outputFD: output[1])
    let pending = Task { try await terminal.question("Paste the code: ", signal: token) }
    pending.cancel()
    do {
        _ = try await pending.value
        Issue.record("Cancelled prompt returned a value")
    } catch is LoginPromptError {
        #expect(!token.isCancelled)
    } catch {
        Issue.record("Unexpected prompt error: \(error)")
    }
}
