import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// Upstream v1.0.0: port all five 5433-extension-oauth-prompt-input regression cases.
@MainActor @Suite(.serialized) struct LoginDialogFlowTests {
    private func dialog() -> LoginDialogComponent {
        initTheme("dark")
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()),
            providerId: "prompt-repro", providerName: "Prompt Repro", onComplete: { _, _ in })
        dialog.authBrowserOpener = { _ in true }
        // D3: inject the explicit URL copy operation; do not copy on display.
        dialog.authURLCopy = { _ in .success }
        return dialog
    }

    private func lines(_ dialog: LoginDialogComponent) -> [String] {
        stripTerminalSequences(dialog.render(width: 120).joined(separator: "\n"))
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func waitForPrompt(_ message: String, dialog: LoginDialogComponent) async {
        for _ in 0..<100 {
            if lines(dialog).contains(where: { $0.contains(message) }) { return }
            await Task.yield()
        }
        Issue.record("Prompt did not appear: \(message)")
    }

    @Test func earlierPromptInputStaysStable() async throws {
        let dialog = dialog()
        let first = Task { try await dialog.showPrompt("First prompt:", "first-value") }
        await waitForPrompt("First prompt:", dialog: dialog)
        dialog.handleInput("first-value")
        dialog.handleInput("\n")
        #expect(try await first.value == "first-value")
        let second = Task { try await dialog.showPrompt("Second prompt:") }
        await waitForPrompt("Second prompt:", dialog: dialog)
        dialog.handleInput("second-secret-demo")
        #expect(lines(dialog).filter { $0 == "> first-value" }.count == 1)
        #expect(lines(dialog).filter { $0 == "> second-secret-demo" }.count == 1)
        dialog.handleInput("\n")
        #expect(try await second.value == "second-secret-demo")
    }

    @Test func promptKeepsAuthInstructions() async throws {
        let dialog = dialog()
        dialog.showAuth("https://example.invalid/login", "Authorize the extension")
        let prompt = Task { try await dialog.showPrompt("First prompt:") }
        await waitForPrompt("First prompt:", dialog: dialog)
        let output = lines(dialog).joined(separator: "\n")
        #expect(output.contains("https://example.invalid/login"))
        #expect(output.contains("Authorize the extension"))
        // D3: show the copy key hint until the user presses the key.
        #expect(output.contains("to copy"))
#if os(macOS)
        #expect(output.contains("Cmd+click to open"))
#else
        #expect(output.contains("Ctrl+click to open"))
#endif
        dialog.handleInput("\n")
        _ = try await prompt.value
    }

    @Test func promptKeepsInfoAndLinks() async throws {
        let dialog = dialog()
        dialog.showInfo("Configure credentials outside pi.", links: [
            AuthInfoLink(url: "https://example.invalid/docs", label: "Provider documentation")])
        let prompt = Task { try await dialog.showPrompt("Press Enter to continue:") }
        await waitForPrompt("Press Enter to continue:", dialog: dialog)
        let output = lines(dialog).joined(separator: "\n")
        #expect(output.contains("Configure credentials outside pi."))
        #expect(output.contains("Provider documentation: https://example.invalid/docs"))
        dialog.handleInput("\n")
        _ = try await prompt.value
    }

    @Test func promptKeepsDetails() async throws {
        let dialog = dialog()
        dialog.showDetails(["AWS credential setup:", "providers.md"])
        let prompt = Task { try await dialog.showPrompt("Enter API key:") }
        await waitForPrompt("Enter API key:", dialog: dialog)
        let output = lines(dialog).joined(separator: "\n")
        #expect(output.contains("AWS credential setup:"))
        #expect(output.contains("providers.md"))
        dialog.handleInput("\n")
        _ = try await prompt.value
    }

    @Test func earlierManualInputStaysStable() async throws {
        let dialog = dialog()
        let manual = Task { try await dialog.showManualInput("Paste callback URL:") }
        await waitForPrompt("Paste callback URL:", dialog: dialog)
        dialog.handleInput("callback-value")
        dialog.handleInput("\n")
        #expect(try await manual.value == "callback-value")
        let prompt = Task { try await dialog.showPrompt("Second prompt:") }
        await waitForPrompt("Second prompt:", dialog: dialog)
        dialog.handleInput("second-secret-demo")
        #expect(lines(dialog).filter { $0 == "> callback-value" }.count == 1)
        #expect(lines(dialog).filter { $0 == "> second-secret-demo" }.count == 1)
        dialog.handleInput("\n")
        #expect(try await prompt.value == "second-secret-demo")
    }

    @Test func secretSubmissionHasBoundedMask() async throws {
        for value in ["", "abc", "long-secret-value"] {
            let dialog = dialog()
            let prompt = Task { try await dialog.showPrompt("Enter secret:", secret: true) }
            await waitForPrompt("Enter secret:", dialog: dialog)
            dialog.handleInput(value)
            dialog.handleInput("\n")
            #expect(try await prompt.value == value)
            let output = lines(dialog)
            let masked = "> " + String(repeating: "•", count: min(value.count, 8))
            #expect(output.contains(masked.trimmingCharacters(in: .whitespaces)))
            if !value.isEmpty { #expect(!output.joined(separator: "\n").contains(value)) }
        }
    }

    @Test func cancellationRejectsPendingPromptAndFuturePrompt() async {
        let dialog = dialog()
        let prompt = Task { try await dialog.showPrompt("Pending:") }
        await waitForPrompt("Pending:", dialog: dialog)
        dialog.signal.cancel()
        do {
            _ = try await prompt.value
            Issue.record("Cancelled prompt returned a value")
        } catch { #expect(error.localizedDescription == "Login cancelled") }
        do {
            _ = try await dialog.showPrompt("Later:")
            Issue.record("Cancelled dialog accepted a prompt")
        } catch { #expect(error.localizedDescription == "Login cancelled") }
    }

    @Test func cancelledManualTaskLeavesDialogUsable() async throws {
        let dialog = dialog()
        let manual = Task { try await dialog.showManualInput("Paste callback URL:") }
        await waitForPrompt("Paste callback URL:", dialog: dialog)
        manual.cancel()
        do {
            _ = try await manual.value
            Issue.record("Cancelled manual input returned a value")
        } catch { #expect(error.localizedDescription == "Login cancelled") }
        #expect(!dialog.signal.isCancelled)
        let next = Task { try await dialog.showPrompt("Next prompt:") }
        await waitForPrompt("Next prompt:", dialog: dialog)
        dialog.handleInput("next")
        dialog.handleInput("\n")
        #expect(try await next.value == "next")
    }

    @Test func titleAndAmbientCloseHint() {
        initTheme("dark")
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()),
            providerId: "ambient", providerName: "Ambient Provider", title: "Ambient Provider setup",
            onComplete: { _, _ in })
        dialog.showInfo("Authentication is configured outside pi.", showCloseHint: true)
        let output = lines(dialog).joined(separator: "\n")
        #expect(output.contains("Ambient Provider setup"))
        #expect(output.contains("(Escape to close)"))
    }
}
