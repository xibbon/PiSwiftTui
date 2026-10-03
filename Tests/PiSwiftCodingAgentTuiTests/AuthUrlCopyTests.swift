import Foundation
import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// Upstream v1.0.1: auth-url-copy.test.ts. Use the default app keys.
@MainActor @Suite(.serialized) struct AuthUrlCopyTests {
    private let authorizationURL = "https://auth.example.invalid/authorize?" + String(repeating: "x", count: 300)
    private let copyKey = "\u{0018}"

    private func setDefaultKeys() {
        initTheme("dark")
        _ = KeybindingsManager.create(agentDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-auth-copy-\(UUID().uuidString)").path)
    }

    private func rendered(_ component: any Component, width: Int = 80) -> String {
        stripTerminalSequences(component.render(width: width).joined(separator: "\n"))
    }

    private func waitFor(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !check() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Sign-in input did not appear")
                throw AuthCopyTestError.waitExpired
            }
            await Task.yield()
        }
    }

    @Test func loginCopiesAuthURLWithoutChangingCodeInput() async throws {
        setDefaultKeys()
        var copied: [String] = []
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "test",
                                          onComplete: { _, _ in })
        dialog.authBrowserOpener = { _ in true }
        dialog.authURLCopy = { copied.append($0); return .success }
        dialog.showAuth(authorizationURL, nil)
        let task = Task { try await dialog.showManualInput("Paste the code:") }
        defer { task.cancel() }
        try await waitFor { rendered(dialog).contains("Paste the code:") }
        #expect(rendered(dialog).contains("ctrl+x to copy"))
        #expect(copied.isEmpty)
        dialog.handleInput("code-value")
        dialog.handleInput(copyKey)
        #expect(rendered(dialog).contains("Copied URL to clipboard"))
        #expect(copied == [authorizationURL])
        dialog.handleInput("\n")
        #expect(try await task.value == "code-value")
    }

    @Test func loginIgnoresCopyKeyAfterAuthURLIsCleared() {
        setDefaultKeys()
        var copied: [String] = []
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "test",
                                          onComplete: { _, _ in })
        dialog.authBrowserOpener = { _ in true }
        dialog.authURLCopy = { copied.append($0); return .success }
        dialog.showAuth(authorizationURL, nil)
        // Swift device flows use showAuth. showDetails clears the URL in both hosts.
        dialog.showDetails(["Enter the device code ABCD"])
        dialog.handleInput(copyKey)
        #expect(copied.isEmpty)
        #expect(!rendered(dialog).contains("to copy"))
    }

    @Test func mcpSignInCopiesAuthorizationURLWithoutChangingRedirectInput() async throws {
        setDefaultKeys()
        var copied: [String] = []
        let view = McpManagerView(theme: theme, requestRender: {})
        view.authURLCopy = { copied.append($0); return .success }
        let url = try #require(URL(string: authorizationURL))
        let task = Task { await view.redirectURL(title: "Sign in to issues", authorizationURL: url) }
        defer { task.cancel(); view.dispose() }
        try await waitFor { rendered(view).contains("ctrl+x to copy") }
        #expect(copied.isEmpty)
        view.handleInput("https://example.invalid/callback?code=value")
        view.handleInput(copyKey)
        #expect(rendered(view).contains("Copied URL to clipboard"))
        #expect(copied == [authorizationURL])
        view.handleInput("\r")
        #expect(await task.value?.absoluteString == "https://example.invalid/callback?code=value")
    }

    @Test func authURLCopyReportsColorsAndRequestsRender() {
        setDefaultKeys()
        let outcomes: [(PiSwiftCodingAgent.ClipboardCopyResult, ThemeColor, String)] = [
            (.success, .success, "Copied URL to clipboard"),
            (.osc52SentUnverified, .warning, "Sent a copy request to the terminal; clipboard not verified"),
            (.failure("Backend unavailable"), .error, "Backend unavailable"),
        ]
        for (result, color, message) in outcomes {
            var redraws = 0
            let link = AuthUrlComponent(url: authorizationURL, requestRender: { redraws += 1 },
                                        clipboardCopy: { _ in result })
            #expect(redraws == 1)
            #expect(rendered(link).contains("ctrl+x to copy"))
            link.copy()
            #expect(redraws == 2)
            #expect(link.render(width: 500).joined(separator: "\n").contains(theme.fg(color, message)))
        }
    }
}

private enum AuthCopyTestError: Error { case waitExpired }
