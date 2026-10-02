import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

func loginTestRegistry() -> ModelRegistry {
    ModelRegistry(.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
}

@MainActor @Suite(.serialized) struct LoginFlowTests {
    private func makeMode(auth: AuthStorage = .inMemory()) -> (AgentSession, InteractiveMode, CustomEditor) {
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let session = t3aSession(registry: registry)
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        editor.setText("Draft text")
        return (session, InteractiveMode(session: session, tui: TUI(terminal: ToolTestTerminal()), editor: editor), editor)
    }

    private func screen(_ mode: InteractiveMode) -> String {
        mode.editorContainer.map { toolTestText($0) } ?? ""
    }

    private func press(_ mode: InteractiveMode, _ key: String) {
        mode.editorContainer?.children.first?.handleInput(key)
    }

    private func waitFor(_ mode: InteractiveMode, text: String) async -> Bool {
        for _ in 0..<1000 {
            if screen(mode).contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    // interactive-mode.ts v1.0.0: an exact single-method reference starts the dialog.
    @Test func singleMatchStartsLoginAndCancelRestoresEditor() async {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        let login = Task { await mode.handleLoginCommand("  Groq  ") }
        #expect(await waitFor(mode, text: "Enter Groq API key"))
        #expect(screen(mode).contains("Login to Groq"))
        press(mode, "\u{001B}")
        await login.value
        #expect(mode.editorContainer?.children.first === editor)
        #expect(editor.getText() == "Draft text")
        #expect(!toolTestText(mode.chatContainer).contains("Login cancelled"))
    }

    @Test func sameIdMatchesOpenProviderMethodMenu() async {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        await mode.handleLoginCommand("OpenAI")
        #expect(screen(mode).contains("Select authentication method for OpenAI:"))
        #expect(screen(mode).contains("Sign in with ChatGPT"))
        #expect(screen(mode).contains("Sign in with an API key"))
        press(mode, "\u{001B}")
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func unmatchedReferenceOpensSelectorWithSearchText() async {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        await mode.handleLoginCommand("unmatched-provider")
        #expect(screen(mode).contains("Select provider to configure:"))
        #expect(screen(mode).contains("unmatched-provider"))
        #expect(screen(mode).contains("No matching providers"))
        press(mode, "\u{001B}")
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func providerSelectorCancelReturnsToAuthTypeMenu() async {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        await mode.handleLoginCommand(nil)
        press(mode, "\u{001B}[B")
        press(mode, "\r")
        #expect(screen(mode).contains("Select provider to configure:"))
        // A selector with one auth type hides the type label (upstream v1.0.0).
        #expect(screen(mode).contains("Amazon Bedrock"))
        press(mode, "\u{001B}")
        #expect(screen(mode).contains("Select authentication method:"))
        press(mode, "\u{001B}")
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func dialogCancelReturnsToProviderSelector() async {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        mode.showLoginProviderSelector(.apiKey, initialSearchInput: "groq")
        press(mode, "\r")
        #expect(await waitFor(mode, text: "Enter Groq API key"))
        press(mode, "\u{001B}")
        #expect(await waitFor(mode, text: "Select provider to configure:"))
        #expect(screen(mode).contains("groq"))
        #expect(!toolTestText(mode.chatContainer).contains("Login cancelled"))
    }

    @Test func dialogCancelReturnsToProviderMethodMenu() async {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        await mode.handleLoginCommand("openai")
        press(mode, "\u{001B}[B")
        press(mode, "\r")
        #expect(await waitFor(mode, text: "Enter OpenAI API key"))
        press(mode, "\u{001B}")
        #expect(await waitFor(mode, text: "Select authentication method for OpenAI:"))
        #expect(screen(mode).contains("Sign in with ChatGPT"))
    }

    @Test func logoutWithoutStoredCredentialsExplainsScope() {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        mode.showOAuthSelector(.logout)
        let status = toolTestText(mode.chatContainer).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(status.contains("No stored credentials to remove. /logout only removes credentials saved by /login; environment variables and models.json config are unchanged."))
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func logoutRemovesApiKeyAndReportsScope() async {
        let auth = AuthStorage.inMemory(["groq": .apiKey(ApiKeyCredential(key: "fake-key"))])
        let (session, mode, editor) = makeMode(auth: auth)
        defer { session.dispose() }
        mode.showOAuthSelector(.logout)
        #expect(screen(mode).contains("Select provider to logout:"))
        #expect(screen(mode).contains("Groq"))
        press(mode, "\r")
        for _ in 0..<1000 {
            if toolTestText(mode.chatContainer).contains("Removed stored API key for Groq.") { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(auth.listCredentials().isEmpty)
        #expect(toolTestText(mode.chatContainer).contains("Removed stored API key for Groq. Environment variables and models.json config are unchanged."))
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func anthropicMethodSelectReturnsOptionIdAndRestoresDialog() async throws {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "anthropic", providerName: "Anthropic", onComplete: { _, _ in })
        let prompt = OAuthSelectPrompt(message: "Select Anthropic login method:", options: [
            OAuthSelectOption(id: "browser", label: "Browser login (default)"),
            OAuthSelectOption(id: "copy_code", label: "Copy code login (headless)"),
        ])
        let selection = Task { try await mode.showAuthSelect(dialog: dialog, prompt: prompt) }
        #expect(await waitFor(mode, text: prompt.message))
        press(mode, "\u{001B}[B")
        press(mode, "\r")
        #expect(try await selection.value == "copy_code")
        #expect(mode.editorContainer?.children.first === dialog)
    }

    @Test func authSelectEscapeAndSignalCancelThrowLoginCancelled() async {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        let prompt = OAuthSelectPrompt(message: "Choose method:", options: [OAuthSelectOption(id: "browser", label: "Browser")])
        for cancelWithSignal in [false, true] {
            let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "anthropic", onComplete: { _, _ in })
            let selection = Task { try await mode.showAuthSelect(dialog: dialog, prompt: prompt) }
            #expect(await waitFor(mode, text: prompt.message))
            if cancelWithSignal { dialog.signal.cancel() } else { press(mode, "\u{001B}") }
            do {
                _ = try await selection.value
                Issue.record("A cancelled select prompt returned a value.")
            } catch {
                #expect(error.localizedDescription == "Login cancelled")
            }
            #expect(mode.editorContainer?.children.first === dialog)
        }
    }

    @Test func authSelectRejectsSignalCancelledBeforePrompt() async {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "anthropic", onComplete: { _, _ in })
        dialog.signal.cancel()
        do {
            _ = try await mode.showAuthSelect(dialog: dialog, prompt: OAuthSelectPrompt(message: "Choose:", options: [OAuthSelectOption(id: "browser", label: "Browser")]))
            Issue.record("A cancelled select prompt opened.")
        } catch {
            #expect(error.localizedDescription == "Login cancelled")
        }
    }

    @Test func ambientDialogShowsSetupAndReturnsToCaller() {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        let option = AuthSelectorProvider(id: "ambient-test", name: "Ambient Test", authType: .apiKey,
            method: .apiKey(ApiKeyAuthMethod(name: "External credentials", envVars: [])))
        var returned = false
        mode.showAmbientAuthDialog(option, onBack: { returned = true })
        #expect(screen(mode).contains("Ambient Test setup"))
        #expect(screen(mode).contains("External credentials is configured outside pi."))
        #expect(screen(mode).contains("(Escape to close)"))
        press(mode, "\u{001B}")
        #expect(returned)
        #expect(mode.editorContainer?.children.first === editor)
        #expect(session.modelRegistry.authStorage.listCredentials().isEmpty)
    }

    @Test func bedrockLoginShowsMethodChoiceAndProfileGuidance() async {
        let (session, mode, editor) = makeMode()
        defer { session.dispose() }
        let login = Task { await mode.handleLoginCommand("amazon-bedrock") }
        #expect(await waitFor(mode, text: "Select Amazon Bedrock authentication method:"))
        #expect(screen(mode).contains("Bearer token"))
        #expect(screen(mode).contains("AWS profile"))
        #expect(screen(mode).contains("Existing AWS credential chain"))
        press(mode, "\u{001B}[B")
        press(mode, "\r")
        #expect(await waitFor(mode, text: "Enter AWS profile name"))
        #expect(screen(mode).contains("You can also use an AWS profile, IAM keys, or role-based credentials."))
        #expect(screen(mode).contains("/providers.md"))
        #expect(screen(mode).contains("AWS credential provider chain: https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html"))
        press(mode, "\u{001B}")
        await login.value
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func apiKeyLoginStoresSecretAndReportsCompletion() async {
        let auth = AuthStorage.inMemory()
        let (session, mode, editor) = makeMode(auth: auth)
        defer { session.dispose() }
        let login = Task { await mode.handleLoginCommand("groq") }
        #expect(await waitFor(mode, text: "Enter Groq API key"))
        press(mode, "fake-secret-key")
        press(mode, "\r")
        await login.value
        #expect(await auth.getApiKey("groq") == "fake-secret-key")
        #expect(toolTestText(mode.chatContainer).contains("Saved API key for Groq. Credentials saved to"))
        #expect(!toolTestText(mode.chatContainer).contains("fake-secret-key"))
        #expect(mode.editorContainer?.children.first === editor)
        // Both API-key and OAuth completion must select a model for a new provider.
        for _ in 0..<1000 {
            if session.agent.state.model.provider == "groq" { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(session.agent.state.model.provider == "groq")
    }

    @Test func anthropicOAuthChoiceCancelReturnsToProviderMethodMenu() async {
        let (session, mode, _) = makeMode()
        defer { session.dispose() }
        await mode.handleLoginCommand("anthropic")
        #expect(screen(mode).contains("Select authentication method for Anthropic:"))
        press(mode, "\r")
        #expect(await waitFor(mode, text: "Select Anthropic login method:"))
        #expect(screen(mode).contains("Browser login (default)"))
        #expect(screen(mode).contains("Copy code login (headless)"))
        press(mode, "\u{001B}")
        #expect(await waitFor(mode, text: "Select authentication method for Anthropic:"))
        #expect(!toolTestText(mode.chatContainer).contains("Login cancelled"))
    }

}
