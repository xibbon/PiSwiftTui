import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct PT1KeyHintTests {
    // Upstream extension-keybinding-hints.test.ts: host hints use configured bindings.
    @Test func messageAndEntryRenderersReceiveHostKeyHints() throws {
        let hints = hostKeybindingHints()
        #expect(hints.keyText("app.tools.expand") == keyText(AppAction.expandTools))
        #expect(hints.keyText("unknown.action") == "")
        #expect(toolTestPlain(hints.keyHint("unknown.action", "expand")) == " expand")
        let message = HookMessage(customType: "probe", content: .text("message"), display: true)
        let row = HookMessageComponent(message: message, customRenderer: { _, options, _ in
            MainActor.assumeIsolated {
                Text(options.keybindingHints.keyText("app.tools.expand"), paddingX: 0, paddingY: 0)
            }
        })
        #expect(toolTestText(row).contains(hints.keyText("app.tools.expand")))
        let session = SessionManager.inMemory()
        let id = session.appendCustomEntry("probe", [:])
        guard case .custom(let entry) = try #require(session.getEntry(id)) else {
            Issue.record("Expected custom entry")
            return
        }
        let custom = CustomEntryComponent(entry: entry, renderer: { _, options, _ in
            MainActor.assumeIsolated {
                Text(options.keybindingHints.keyText("tui.select.confirm"), paddingX: 0, paddingY: 0)
            }
        })
        #expect(toolTestText(custom).contains(hints.keyText("tui.select.confirm")))
    }

    @Test func hintsUseUserBindingsAndMacOptionNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            _ = KeybindingsManager.create(agentDir: directory.path)
        }
        try Data(#"{"expandTools":["alt+o"],"tui.select.confirm":["ctrl+j"]}"#.utf8)
            .write(to: directory.appendingPathComponent("keybindings.json"))
        _ = KeybindingsManager.create(agentDir: directory.path)
        let hints = hostKeybindingHints()
        #expect(hints.keyText("app.tools.expand") == "option+o")
        #expect(hints.keyText("tui.select.confirm") == "ctrl+j")
    }

    @Test func toolArgumentsRenderOncePerFrameWithHostHints() {
        var calls = 0
        var lastValue = ""
        let renderers = ToolRenderers(renderCall: { args, _, context in
            calls += 1
            lastValue = args["value"]?.value as? String ?? ""
            #expect(context.keybindingHints.keyText("app.tools.expand") == keyText(AppAction.expandTools))
            return Text(lastValue, paddingX: 0, paddingY: 0)
        })
        let row = ToolExecutionComponent(toolName: "probe", args: [:], renderers: renderers, ui: TUI(terminal: ToolTestTerminal()))
        let initialCalls = calls
        row.updateArgs(["value": AnyCodable("first")])
        row.updateArgs(["value": AnyCodable("last")])
        #expect(calls == initialCalls)
        _ = row.render(width: 80)
        #expect(calls == initialCalls + 1)
        #expect(lastValue == "last")
        _ = row.render(width: 80)
        #expect(calls == initialCalls + 1)
    }
}
