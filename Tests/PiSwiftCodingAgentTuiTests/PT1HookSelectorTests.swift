import MiniTui
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
struct PT1HookSelectorTests {
    // v1.5.2 PT1: extension-selector.ts:88–106 bounds the list and shows its position.
    @Test func tenVisibleOptionsAndPositionIndicator() {
        let options = (1...25).map { "choice \($0)" }
        let selector = HookSelectorComponent(title: "Pick", options: options,
            onSelect: { _ in }, onCancel: {})
        let initial = toolTestText(selector)
        #expect(initial.contains("choice 1"))
        #expect(initial.contains("choice 10"))
        #expect(!initial.contains("choice 11"))
        #expect(initial.contains("(1/25)"))
        selector.handleInput("\u{1B}[6~")
        let next = toolTestText(selector)
        #expect(next.contains("choice 11"))
        #expect(next.contains("(11/25)"))
        #expect(!next.contains("choice 1\n"))
    }
}
