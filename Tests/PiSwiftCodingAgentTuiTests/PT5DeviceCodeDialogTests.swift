import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

// v1.5.2 PT5: login-dialog.ts:149-200,395-409.
@MainActor @Suite(.serialized) struct PT5DeviceCodeDialogTests {
    private func check(openBrowser: Bool, copyCode: Bool, actionText: String?) {
        var opened: [String] = []
        var copied: [String] = []
        let dialog = LoginDialogComponent(tui: TUI(terminal: ToolTestTerminal()), providerId: "device",
                                          onComplete: { _, _ in })
        dialog.focused = true
        dialog.deviceCodeConfirmKeyMatches = { $0 == "\r" }
        dialog.authBrowserOpener = { opened.append($0); return true }
        dialog.authURLCopy = { copied.append($0); return .success }
        dialog.showDeviceCode(OAuthDeviceCodeInfo(userCode: "ABCD-1234",
            verificationUri: "https://example.invalid/device", openBrowserOnConfirm: openBrowser,
            copyCodeOnConfirm: copyCode))

        let before = stripTerminalSequences(dialog.render(width: 120).joined(separator: "\n"))
        #expect(before.contains("https://example.invalid/device"))
        #expect(before.contains("Enter code: ABCD-1234"))
        if let actionText {
            #expect(before.contains(actionText))
        } else {
            #expect(!before.contains("to open browser"))
            #expect(!before.contains("to copy code"))
        }
        #expect(opened.isEmpty)
        #expect(copied.isEmpty)

        dialog.handleInput("\r")
        dialog.handleInput("\r")
        #expect(opened == (openBrowser ? ["https://example.invalid/device"] : []))
        #expect(copied == (copyCode ? ["ABCD-1234"] : []))
        let after = stripTerminalSequences(dialog.render(width: 120).joined(separator: "\n"))
        if copyCode { #expect(after.contains("Code copied to clipboard")) }
        else if openBrowser { #expect(after.contains("Browser open requested")) }
    }

    @Test func browserAndCode() { check(openBrowser: true, copyCode: true, actionText: "to open browser and copy code") }
    @Test func browserOnly() { check(openBrowser: true, copyCode: false, actionText: "to open browser") }
    @Test func codeOnly() { check(openBrowser: false, copyCode: true, actionText: "to copy code") }
    @Test func neitherAction() { check(openBrowser: false, copyCode: false, actionText: nil) }
}
