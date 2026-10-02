import Foundation
import Testing
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

private func loginMenuProviders() -> [LoginProviderInfo] {
    [LoginProviderInfo(id: "anthropic", name: "Anthropic",
        apiKey: ApiKeyAuthMethod(name: "Anthropic API key", envVars: []),
        oauth: OAuthProviderInfo(id: .anthropic, name: "Anthropic (Claude Pro/Max)", available: true, isSubscription: true)),
     LoginProviderInfo(id: "google-vertex", name: "Google Vertex AI",
        apiKey: ApiKeyAuthMethod(name: "Google Cloud credentials", envVars: [])),
     LoginProviderInfo(id: "openrouter", name: "OpenRouter",
        apiKey: ApiKeyAuthMethod(name: "OpenRouter API key", envVars: []),
        oauth: OAuthProviderInfo(id: .openRouter, name: "OpenRouter OAuth", available: true))]
}

private func loginMenuPlain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
}

private func loginMenuRow(_ source: ProviderAuthStatus, oauth: Bool = false) -> AuthSelectorProvider {
    getLoginProviderOptions(Array(loginMenuProviders().prefix(1)), authType: .apiKey,
        authStatus: { _ in source }, isUsingOAuth: { _ in oauth })[0]
}

// Port of v1.0.0 oauth-selector.test.ts: provider-owned auth methods, including ambient methods.
@Test func loginOptionsProjectProviderOwnedMethods() {
    let providers = Array(loginMenuProviders().prefix(2))
    let keys = getLoginProviderOptions(providers, authType: .apiKey)
    #expect(keys.map(\.id) == ["anthropic", "google-vertex"])
    #expect(keys.map { $0.method?.name } == ["Anthropic API key", "Google Cloud credentials"])
    #expect(getLoginProviderOptions(providers, authType: .oauth).map(\.id) == ["anthropic"])
}

@Test @MainActor func loginSelectorWithoutAuthStatusIsNotConfigured() {
    let selector = OAuthSelectorComponent(mode: .login,
        providers: [AuthSelectorProvider(id: "google", name: "Google", authType: .apiKey)],
        onSelect: { _, _ in }, onCancel: {})
    let output = loginMenuPlain(selector.render(width: 120).joined(separator: "\n"))
    #expect(output.contains(" • not configured"))
    #expect(!output.contains("✓ configured"))
}

@Test func loginSelectorShowsOAuthInApiKeySelector() {
    let row = loginMenuRow(ProviderAuthStatus(configured: true, source: "stored"), oauth: true)
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(row)) == " • subscription configured")
}

@Test func loginSelectorShowsEnvironmentAuth() {
    let row = loginMenuRow(ProviderAuthStatus(configured: true, source: "environment", label: "OPENAI_API_KEY"))
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(row)) == " ✓ env: OPENAI_API_KEY")
}

@Test func loginSelectorShowsModelsJsonKeyAuth() {
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(loginMenuRow(
        ProviderAuthStatus(configured: true, source: "models_json_key")))) == " ✓ key in models.json")
}

@Test func loginSelectorShowsModelsJsonCommandAuth() {
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(loginMenuRow(
        ProviderAuthStatus(configured: true, source: "models_json_command")))) == " ✓ command in models.json")
}

@Test func loginStatusMapsRawSourcesAndKeepsLabels() {
    let values: [(String, String)] = [("stored", " ✓ configured"), ("fallback", " ✓ extension"),
        ("runtime", " ✓ runtime"), ("environment", " ✓ environment")]
    for (source, expected) in values {
        #expect(loginMenuPlain(formatAuthSelectorProviderStatus(loginMenuRow(
            ProviderAuthStatus(configured: true, source: source)))) == expected)
    }
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(loginMenuRow(
        ProviderAuthStatus(configured: true, source: "environment", label: "workload identity federation"))))
        == " ✓ workload identity federation")
    let row = AuthSelectorProvider(id: "p", name: "P", authType: .oauth,
        status: AuthSelectorStatus(type: .apiKey), subscription: false)
    #expect(loginMenuPlain(formatAuthSelectorProviderStatus(row)) == " • API key configured")
}

@Test func loginOptionsHideUnavailableOAuthMethods() {
    let provider = LoginProviderInfo(id: "openai-codex", name: "OpenAI Codex (legacy)",
        oauth: OAuthProviderInfo(id: .openAICodex, name: "Codex", available: false, isSubscription: true))
    #expect(getLoginProviderOptions([provider]).isEmpty)
}

// Port of v1.0.0 interactive-mode-status.test.ts:456, using OpenRouter for account auth.
@Test func loginCompletionMatchesProviderIdNameAndAuthType() {
    let options = getLoginProviderOptions(loginMenuProviders())
    let anthropic = getLoginProviderCompletions(options, query: "subscription anthrop")
    #expect(anthropic?.count == 1)
    #expect(anthropic?.first?.value == "anthropic")
    #expect(anthropic?.first?.label == "anthropic")
    #expect(anthropic?.first?.description == "Anthropic · subscription/API key")
    let router = getLoginProviderCompletions(options, query: "account openrouter")
    #expect(router?.count == 1)
    #expect(router?.first?.description == "OpenRouter · account/API key")
    #expect(getLoginProviderCompletions(options, query: "zzzzzzzzzzzz") == nil)
}

@Test @MainActor func loginSelectorSearchSelectAndCancel() {
    var selected: (String, AuthType)?
    var cancelled = false
    let selector = OAuthSelectorComponent(mode: .login, providers: getLoginProviderOptions(loginMenuProviders()),
        onSelect: { selected = ($0, $1) }, onCancel: { cancelled = true }, initialSearchInput: "vertex")
    #expect(selector.getSearchInput().getValue() == "vertex")
    let output = loginMenuPlain(selector.render(width: 120).joined(separator: "\n"))
    #expect(output.contains("Google Vertex AI [API key]"))
    #expect(!output.contains("Anthropic"))
    selector.handleInput("\r")
    #expect(selected?.0 == "google-vertex")
    #expect(selected?.1 == .apiKey)
    selector.handleInput("\u{001B}")
    #expect(cancelled)
}

@Test @MainActor func loginSelectorHasEightRowWindowAndClampsNavigation() {
    let rows = (0..<10).map { AuthSelectorProvider(id: "p\($0)", name: "Provider \($0)", authType: .apiKey) }
    var selected = ""
    let selector = OAuthSelectorComponent(mode: .login, providers: rows,
        onSelect: { id, _ in selected = id }, onCancel: {})
    let first = loginMenuPlain(selector.render(width: 120).joined(separator: "\n"))
    #expect(first.contains("(1/10)"))
    #expect(!first.contains("Provider 8"))
    for _ in 0..<12 { selector.handleInput("\u{001B}[B") }
    let last = loginMenuPlain(selector.render(width: 120).joined(separator: "\n"))
    #expect(last.contains("(10/10)"))
    #expect(!last.contains("Provider 0"))
    selector.handleInput("\r")
    #expect(selected == "p9")
}

@Test @MainActor func loginSelectorEmptyMessagesAndTyping() {
    let empty = OAuthSelectorComponent(mode: .login, providers: [], onSelect: { _, _ in }, onCancel: {})
    #expect(loginMenuPlain(empty.render(width: 120).joined(separator: "\n")).contains("No providers available"))
    let logout = OAuthSelectorComponent(mode: .logout, providers: [], onSelect: { _, _ in }, onCancel: {})
    #expect(loginMenuPlain(logout.render(width: 120).joined(separator: "\n")).contains("No providers logged in. Use /login first."))
    let selector = OAuthSelectorComponent(mode: .login, providers: getLoginProviderOptions(loginMenuProviders()),
        onSelect: { _, _ in }, onCancel: {})
    selector.handleInput("zzzzzzzz")
    #expect(loginMenuPlain(selector.render(width: 120).joined(separator: "\n")).contains("No matching providers"))
}
