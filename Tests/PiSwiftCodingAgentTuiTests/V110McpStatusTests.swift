import Foundation
import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor private final class V110McpHost: HookUIHost {}
@MainActor private final class V110McpStatusState {
    var view: McpManagerView?
    var calls = 0
}
private struct V110McpKeys: HookKeybindings {
    func matches(_ data: String, _ action: AppAction) -> Bool { false }
    func getDisplayString(_ action: AppAction) -> String { "" }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct V110McpStatusTests {
    // Upstream v1.1.0 mcp-manager-view.test.ts:25-39.
    @Test func statusCancelRunsOnceAndNextStatusClearsHandler() {
        let view = McpManagerView(theme: theme, requestRender: {})
        let state = V110McpStatusState()
        view.status(title: "Sign in", message: "Contacting the authorization server…", onCancel: { state.calls += 1 })
        #expect(stripTerminalSequences(view.render(width: 80).joined()).contains("cancel"))
        view.handleInput("\u{001B}")
        view.handleInput("\u{001B}")
        #expect(state.calls == 1)
        view.status(title: "Sign in", message: "Connecting…")
        #expect(!stripTerminalSequences(view.render(width: 80).joined()).contains("cancel"))
        view.handleInput("\u{001B}")
        #expect(state.calls == 1)
    }

    @Test func bridgePassesStatusCancelToMountedView() async {
        let bridge = InteractiveMcpUi()
        let state = V110McpStatusState()
        bridge.attach(custom: { factory in
            let component = await factory(V110McpHost(), theme, V110McpKeys(), { _ in })
            state.view = component as? McpManagerView
            let limit = ContinuousClock.now + .seconds(2)
            while state.view?.render(width: 80).joined().contains("Contacting") != true,
                  ContinuousClock.now < limit { await Task.yield() }
            state.view?.handleInput("\u{001B}")
            return nil
        }, requestRender: {}, notify: { _ in })
        await bridge.runManager {
            await bridge.status(title: "Sign in", message: "Contacting", onCancel: { state.calls += 1 })
            let limit = ContinuousClock.now + .seconds(2)
            while await MainActor.run(body: { state.calls == 0 }), ContinuousClock.now < limit { await Task.yield() }
        }
        #expect(state.calls == 1)
    }
}
