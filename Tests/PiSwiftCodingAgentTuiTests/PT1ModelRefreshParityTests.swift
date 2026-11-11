import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct PT1ModelRefreshParityTests {
    private func register(_ ids: [String], in registry: ModelRegistry) {
        registry.registerProvider(HookProviderConfig(provider: "pt1-refresh", api: .openAIResponses,
            baseUrl: "https://example.invalid", apiKey: "test",
            models: ids.map { HookProviderModel(id: $0) }), sourceId: "pt1-refresh")
    }

    private func open(currentID: String = "alpha-1", scopedIDs: [String] = [],
                      ids: [String] = ["alpha-1", "alpha-2", "alpha-3", "beta-1"]) async throws -> (ModelRegistry, ModelSelectorComponent) {
        let registry = ModelRegistry(AuthStorage.inMemory(), nil,
            modelsStore: InMemoryModelsStore(), networkEnabled: false)
        for provider in Set(registry.getAll().map(\.provider)) {
            registry.registerProvider(HookProviderConfig(provider: provider, api: .openAIResponses,
                baseUrl: "https://example.invalid", models: [HookProviderModel]()), sourceId: "pt1-empty-catalogs")
        }
        register(ids, in: registry)
        let current = try #require(registry.find("pt1-refresh", currentID))
        let scoped = try scopedIDs.map { id in
            ScopedModel(model: try #require(registry.find("pt1-refresh", id)))
        }
        let selector = ModelSelectorComponent(tui: TUI(terminal: ToolTestTerminal()), currentModel: current,
            modelRegistry: registry, scopedModels: scoped, onSelect: { _ in }, onCancel: {})
        // Stop the automatic task. Apply each refresh snapshot at a fixed point below.
        selector.closeSelector()
        await selector.loadModelsFromSnapshot()
        return (registry, selector)
    }

    private func selectedID(_ selector: ModelSelectorComponent) -> String? {
        let row = selector.render(width: 120).map { stripTerminalSequences($0) }
            .first { $0.hasPrefix("→") }
        return row?.dropFirst().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "✓ ", with: "").split(separator: " ").first.map(String.init)
    }

    // model-selector.test.ts:220, v1.5.2.
    @Test func followsSelectedModelWhenNewRowsShiftItsPosition() async throws {
        let (registry, selector) = try await open()
        selector.handleInput("\u{1b}[B")
        register(["added-model", "alpha-1", "alpha-2", "alpha-3", "beta-1"], in: registry)

        await selector.loadModelsFromSnapshot()

        #expect(selectedID(selector) == "alpha-2")
        selector.handleInput("\u{1b}[A")
        selector.handleInput("\u{1b}[A")
        #expect(selectedID(selector) == "alpha-1")
    }

    // model-selector.test.ts:239, v1.5.2.
    @Test func fallsBackToCurrentModelWhenSelectedModelDisappears() async throws {
        let (registry, selector) = try await open()
        selector.handleInput("\u{1b}[B")
        register(["alpha-1", "alpha-3", "beta-1"], in: registry)

        await selector.loadModelsFromSnapshot()

        #expect(selectedID(selector) == "alpha-1")
    }

    // model-selector.ts:273–279: a scope change resets selection, then applies the query.
    @Test func scopeChangeAppliesQueryFromFirstMatch() async throws {
        let (_, selector) = try await open(currentID: "beta-1", scopedIDs: ["alpha-2", "alpha-3"])
        for character in "alpha" { selector.handleInput(String(character)) }
        selector.handleInput("\u{1b}[B")
        #expect(selectedID(selector) == "alpha-3")

        selector.handleInput("\t")

        #expect(selector.getSearchInput().getValue() == "alpha")
        #expect(selectedID(selector) == "alpha-1")
        selector.handleInput("\t")
        #expect(selectedID(selector) == "alpha-2")
    }

    // model-selector.ts:304–312: a missing preferred row with a query selects the first match.
    @Test func refreshWithQueryAndMissingSelectionUsesFirstMatch() async throws {
        let (registry, selector) = try await open(currentID: "long-alpha-current",
            ids: ["long-alpha-current", "alpha", "alpha-selected"])
        for character in "alpha" { selector.handleInput(String(character)) }
        #expect(selectedID(selector) == "alpha")
        for _ in 0..<3 where selectedID(selector) != "alpha-selected" {
            selector.handleInput("\u{1b}[B")
        }
        #expect(selectedID(selector) == "alpha-selected")
        register(["long-alpha-current", "alpha"], in: registry)

        await selector.loadModelsFromSnapshot()

        #expect(selector.getSearchInput().getValue() == "alpha")
        #expect(selectedID(selector) == "alpha")
    }
}
