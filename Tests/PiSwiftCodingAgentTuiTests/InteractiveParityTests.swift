import Testing
import PiSwiftAgent
@testable import PiSwiftCodingAgentTui

@Test @MainActor func thinkingSelectorRendersMaxWhenSupported() {
    let selector = ThinkingSelectorComponent(
        currentLevel: .max,
        availableLevels: [.off, .high, .xhigh, .max],
        onSelect: { _ in },
        onCancel: {}
    )
    #expect(selector.getSelectList().render(width: 80).joined(separator: "\n").contains("max"))
}

@Test func loginProviderCompletionsContainProviderIdentifiers() {
    // Upstream v1.0.0: completion reads the live provider registry.
    let options = getLoginProviderCompletionOptions(loginTestRegistry())
    #expect(!options.isEmpty)
    #expect(options.allSatisfy { !$0.value.isEmpty && !$0.label.isEmpty })
}
