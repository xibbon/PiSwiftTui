import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// Upstream v1.4.0 interactive-mode.ts:6064-6082, finishAuthentication.
@MainActor @Suite(.serialized) struct PostLoginDefaultModelTests {
    private func makeMode(provider: String, ids: [String]) -> (AgentSession, InteractiveMode, CustomEditor) {
        let registry = loginTestRegistry()
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAIResponses,
            baseUrl: "https://example.invalid", name: "H1 Provider",
            models: ids.map { HookProviderModel(id: $0) }), sourceId: "h1-login")
        let session = t3aSession(registry: registry)
        let editor = CustomEditor(theme: getEditorTheme(), keybindings: KeybindingsManager.create())
        return (session, InteractiveMode(session: session, tui: TUI(terminal: ToolTestTerminal()), editor: editor), editor)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func login(_ mode: InteractiveMode, provider: String, prompt: String) async {
        let login = Task { await mode.handleLoginCommand(provider) }
        #expect(await waitFor { mode.editorContainer.map { toolTestText($0).contains(prompt) } ?? false })
        mode.editorContainer?.children.first?.handleInput("h1-test-key")
        mode.editorContainer?.children.first?.handleInput("\r")
        await login.value
    }

    private func chat(_ mode: InteractiveMode) -> String {
        toolTestText(mode.chatContainer, width: 400)
    }

    @Test func loginWithoutConfiguredDefaultNamesProviderBeforeCheckingModels() async {
        // Check both catalogs. An empty catalog must still report the missing default first.
        for ids in [[], ["other-model"]] {
            let (session, mode, editor) = makeMode(provider: "h1-no-default", ids: ids)
            defer { session.dispose() }
            await login(mode, provider: "h1-no-default", prompt: "Enter API key")
            let expected = "Saved API key for H1 Provider, but no default model is configured for provider \"h1-no-default\". Use /model to select a model."
            #expect(await waitFor { chat(mode).contains(expected) })
            #expect(!chat(mode).contains("no models are available"))
            #expect(await session.modelRegistry.authStorage.getApiKey("h1-no-default") == "h1-test-key")
            #expect(mode.editorContainer?.children.first === editor)
        }
    }

    @Test func loginWithDefaultAndEmptyCatalogKeepsNoModelsMessage() async {
        let (session, mode, editor) = makeMode(provider: "groq", ids: [])
        defer { session.dispose() }
        await login(mode, provider: "groq", prompt: "Enter Groq API key")
        let expected = "Saved API key for H1 Provider, but no models are available for that provider. Use /model to select a model."
        #expect(await waitFor { chat(mode).contains(expected) })
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func loginWithUnavailableDefaultNamesExpectedModelId() async {
        let (session, mode, editor) = makeMode(provider: "groq", ids: ["other-model"])
        defer { session.dispose() }
        await login(mode, provider: "groq", prompt: "Enter Groq API key")
        let expected = "Saved API key for H1 Provider, but its default model \"openai/gpt-oss-120b\" is not available. Use /model to select a model."
        #expect(await waitFor { chat(mode).contains(expected) })
        #expect(mode.editorContainer?.children.first === editor)
    }

    @Test func defaultModelSelectionFailureIncludesActionErrorAndModelHint() async throws {
        let (session, mode, _) = makeMode(provider: "h1-selection-failure", ids: ["default"])
        defer { session.dispose() }
        let model = try #require(session.modelRegistry.find("h1-selection-failure", "default"))
        // Call the shared application step with no credentials to make the real setModel throw.
        await mode.applyPostLoginDefaultModel(model, session: session, actionLabel: "Logged in to H1 Provider")
        let expected = "Logged in to H1 Provider, but selecting its default model failed: No API key for h1-selection-failure/default. Use /model to select a model."
        #expect(chat(mode).contains(expected))
        #expect(session.agent.state.model.provider == "test")
        #expect(session.agent.state.model.id == "selected")
    }
}
