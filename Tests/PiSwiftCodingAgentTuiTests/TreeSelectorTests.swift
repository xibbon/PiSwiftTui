import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

private func makeUserEntry(id: String, parentId: String?, content: String) -> SessionMessageEntry {
    let message = UserMessage(content: .text(content), timestamp: Int64(Date().timeIntervalSince1970 * 1000))
    return SessionMessageEntry(id: id, parentId: parentId, timestamp: ISO8601DateFormatter().string(from: Date()), message: .user(message))
}

private func makeAssistantEntry(id: String, parentId: String?, text: String) -> SessionMessageEntry {
    let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    let assistant = AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-sonnet-4",
        usage: usage,
        stopReason: .stop,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000)
    )
    return SessionMessageEntry(id: id, parentId: parentId, timestamp: ISO8601DateFormatter().string(from: Date()), message: .assistant(assistant))
}

private func makeModelChangeEntry(id: String, parentId: String?) -> ModelChangeEntry {
    ModelChangeEntry(id: id, parentId: parentId, timestamp: ISO8601DateFormatter().string(from: Date()), provider: "anthropic", modelId: "claude-sonnet-4")
}

private func makeThinkingLevelEntry(id: String, parentId: String?) -> ThinkingLevelChangeEntry {
    ThinkingLevelChangeEntry(id: id, parentId: parentId, timestamp: ISO8601DateFormatter().string(from: Date()), thinkingLevel: "high")
}

private func buildTree(entries: [SessionEntry]) -> [SessionTreeNode] {
    final class NodeBox {
        var entry: SessionEntry
        var children: [NodeBox] = []
        var label: String?

        init(entry: SessionEntry) {
            self.entry = entry
        }

        func toNode() -> SessionTreeNode {
            SessionTreeNode(
                entry: entry,
                children: children.map { $0.toNode() },
                label: label
            )
        }
    }

    func parentId(for entry: SessionEntry) -> String? {
        switch entry {
        case .message(let entry): return entry.parentId
        case .thinkingLevel(let entry): return entry.parentId
        case .modelChange(let entry): return entry.parentId
        case .compaction(let entry): return entry.parentId
        case .branchSummary(let entry): return entry.parentId
        case .custom(let entry): return entry.parentId
        case .customMessage(let entry): return entry.parentId
        case .usage(let entry): return entry.parentId
        case .contextEdit(let entry): return entry.parentId
        case .label(let entry): return entry.parentId
        case .sessionInfo(let entry): return entry.parentId
        }
    }

    var boxes: [String: NodeBox] = [:]
    for entry in entries {
        boxes[entry.id] = NodeBox(entry: entry)
    }

    var roots: [NodeBox] = []
    for entry in entries {
        guard let node = boxes[entry.id] else { continue }
        if let parentId = parentId(for: entry), let parent = boxes[parentId] {
            parent.children.append(node)
        } else {
            roots.append(node)
        }
    }

    return roots.map { $0.toNode() }
}

private func initThemeForTests() {
    initTheme("dark")
}

@MainActor @Test func treeSelectorInitialSelectionSkipsModelChange() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
        .message(makeUserEntry(id: "user-2", parentId: "asst-1", content: "active branch")),
        .modelChange(makeModelChangeEntry(id: "model-1", parentId: "user-2")),
        .message(makeUserEntry(id: "user-3", parentId: "asst-1", content: "sibling branch")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "model-1", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "user-2")
}

@MainActor @Test func treeSelectorInitialSelectionSkipsThinkingLevelChange() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
        .message(makeUserEntry(id: "user-2", parentId: "asst-1", content: "active branch")),
        .thinkingLevel(makeThinkingLevelEntry(id: "thinking-1", parentId: "user-2")),
        .message(makeUserEntry(id: "user-3", parentId: "asst-1", content: "sibling branch")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "thinking-1", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "user-2")
}

@MainActor @Test func treeSelectorUserOnlyFilterSelectsNearestUser() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
        .message(makeUserEntry(id: "user-2", parentId: "asst-1", content: "active branch")),
        .message(makeAssistantEntry(id: "asst-2", parentId: "user-2", text: "response")),
        .message(makeUserEntry(id: "user-3", parentId: "asst-1", content: "sibling branch")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "asst-2", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "asst-2")
    selector.handleInput("\u{15}") // Ctrl+U
    #expect(selector.getSelectedEntryId() == "user-2")
}

@MainActor @Test func treeSelectorReturnsToNearestAncestorWhenSwitchingBackToDefault() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
        .message(makeUserEntry(id: "user-2", parentId: "asst-1", content: "active branch")),
        .message(makeAssistantEntry(id: "asst-2", parentId: "user-2", text: "response")),
        .message(makeUserEntry(id: "user-3", parentId: "asst-1", content: "sibling branch")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "asst-2", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "asst-2")
    selector.handleInput("\u{15}") // Ctrl+U
    #expect(selector.getSelectedEntryId() == "user-2")
    selector.handleInput("\u{04}") // Ctrl+D
    #expect(selector.getSelectedEntryId() == "user-2")
}

@MainActor @Test func treeSelectorPreservesSelectionAcrossEmptyFilter() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
        .message(makeUserEntry(id: "user-2", parentId: "asst-1", content: "bye")),
        .message(makeAssistantEntry(id: "asst-2", parentId: "user-2", text: "goodbye")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "asst-2", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "asst-2")
    selector.handleInput("\u{0C}") // Ctrl+L (labeled-only)
    #expect(selector.getSelectedEntryId() == nil)
    selector.handleInput("\u{04}") // Ctrl+D
    #expect(selector.getSelectedEntryId() == "asst-2")
}

@MainActor @Test func treeSelectorPreservesSelectionThroughMultipleEmptyFilters() {
    initThemeForTests()

    let entries: [SessionEntry] = [
        .message(makeUserEntry(id: "user-1", parentId: nil, content: "hello")),
        .message(makeAssistantEntry(id: "asst-1", parentId: "user-1", text: "hi")),
    ]
    let tree = buildTree(entries: entries)
    let selector = TreeSelectorComponent(tree: tree, currentLeafId: "asst-1", terminalHeight: 24, onSelect: { _ in }, onCancel: { })

    #expect(selector.getSelectedEntryId() == "asst-1")
    selector.handleInput("\u{0C}") // Ctrl+L
    #expect(selector.getSelectedEntryId() == nil)
    selector.handleInput("\u{0C}") // Ctrl+L back to default
    #expect(selector.getSelectedEntryId() == "asst-1")
    selector.handleInput("\u{0C}") // Ctrl+L again
    #expect(selector.getSelectedEntryId() == nil)
    selector.handleInput("\u{04}") // Ctrl+D
    #expect(selector.getSelectedEntryId() == "asst-1")
}
