import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private struct FlatNode {
    let node: SessionTreeNode
    let indent: Int
}

private final class TreeList: Component {
    private var flatNodes: [FlatNode]
    private var filteredNodes: [FlatNode]
    private var selectedIndex = 0
    private var searchQuery = ""
    private var labels: [String: String?] = [:]
    private var currentLeafId: String?
    private var lastSelectedId: String?
    private var filterMode: FilterMode = .default

    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onLabelEdit: ((String, String?) -> Void)?

    private enum FilterMode {
        case `default`
        case userOnly
        case labeledOnly
    }

    init(tree: [SessionTreeNode], currentLeafId: String?, maxVisibleLines: Int) {
        self.flatNodes = TreeList.flatten(tree)
        self.filteredNodes = flatNodes
        self.currentLeafId = currentLeafId

        for node in flatNodes {
            labels[node.node.entry.id] = node.node.label
        }

        self.lastSelectedId = currentLeafId
        applyFilter(preserveSelectionSnapshot: false)

        _ = maxVisibleLines
    }

    func updateNodeLabel(_ entryId: String, _ label: String?) {
        labels[entryId] = label
    }

    func selectedEntryId() -> String? {
        filteredNodes[safe: selectedIndex]?.node.entry.id
    }

    func invalidate() {}

    func render(width: Int) -> [String] {
        if filteredNodes.isEmpty {
            return [truncateToWidth(theme.fg(.muted, "  No entries found"), maxWidth: width, ellipsis: "")]
        }

        var lines: [String] = []
        for (idx, flat) in filteredNodes.enumerated() {
            let isSelected = idx == selectedIndex
            let prefix = isSelected ? theme.fg(.accent, "› ") : "  "
            let indent = String(repeating: "  ", count: max(0, flat.indent))
            let label = labels[flat.node.entry.id] ?? flat.node.label
            let labelPrefix = label.map { theme.fg(.warning, "[\($0)] ") } ?? ""
            let content = labelPrefix + describeEntry(flat.node.entry)
            let line = prefix + theme.fg(.dim, indent) + content
            lines.append(truncateToWidth(isSelected ? theme.bold(line) : line, maxWidth: width, ellipsis: ""))
        }

        return lines
    }

    func handleInput(_ keyData: String) {
        if isArrowUp(keyData) {
            selectedIndex = max(0, selectedIndex - 1)
            return
        }
        if isArrowDown(keyData) {
            selectedIndex = min(filteredNodes.count - 1, selectedIndex + 1)
            return
        }
        if isCtrlU(keyData) {
            filterMode = (filterMode == .userOnly) ? .default : .userOnly
            applyFilter()
            return
        }
        if isCtrlL(keyData) {
            filterMode = (filterMode == .labeledOnly) ? .default : .labeledOnly
            applyFilter()
            return
        }
        if isCtrlD(keyData) {
            filterMode = .default
            applyFilter()
            return
        }
        if isEnter(keyData) {
            if let selected = filteredNodes[safe: selectedIndex] {
                onSelect?(selected.node.entry.id)
            }
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancel?()
            return
        }
        if keyData == "l" {
            if let selected = filteredNodes[safe: selectedIndex] {
                onLabelEdit?(selected.node.entry.id, labels[selected.node.entry.id] ?? nil)
            }
            return
        }
        if isBackspace(keyData) {
            if !searchQuery.isEmpty {
                searchQuery.removeLast()
                applyFilter()
            }
            return
        }

        if keyData.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
            searchQuery.append(keyData)
            applyFilter()
        }
    }

    private func applyFilter(preserveSelectionSnapshot: Bool = true) {
        if preserveSelectionSnapshot, filteredNodes.isEmpty == false {
            lastSelectedId = filteredNodes[safe: selectedIndex]?.node.entry.id ?? lastSelectedId
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredNodes = flatNodes.filter { flat in
            let entry = flat.node.entry
            if !passesFilterMode(entry, node: flat.node) {
                return false
            }
            if trimmed.isEmpty {
                return true
            }
            return describeEntry(entry).lowercased().contains(trimmed.lowercased())
        }

        if let lastSelectedId {
            selectedIndex = findNearestVisibleIndex(lastSelectedId)
        } else {
            selectedIndex = min(selectedIndex, max(0, filteredNodes.count - 1))
        }

        if filteredNodes.isEmpty == false {
            lastSelectedId = filteredNodes[safe: selectedIndex]?.node.entry.id ?? lastSelectedId
        }
    }

    private func passesFilterMode(_ entry: SessionEntry, node: SessionTreeNode) -> Bool {
        // Usage entries are bookkeeping: they stay in the raw tree but are never listed.
        if case .usage = entry { return false }
        let isSettingsEntry: Bool = {
            switch entry {
            case .label, .contextEdit, .custom, .modelChange, .thinkingLevel:
                return true
            default:
                return false
            }
        }()

        switch filterMode {
        case .userOnly:
            if case .message(let message) = entry {
                if case .user = message.message { return true }
            }
            return false
        case .labeledOnly:
            return node.label != nil
        case .default:
            return !isSettingsEntry
        }
    }

    private func findNearestVisibleIndex(_ entryId: String?) -> Int {
        guard filteredNodes.isEmpty == false else { return 0 }
        guard let entryId else { return max(0, filteredNodes.count - 1) }

        var entryMap: [String: SessionEntry] = [:]
        for flat in flatNodes {
            entryMap[flat.node.entry.id] = flat.node.entry
        }

        var visibleMap: [String: Int] = [:]
        for (idx, flat) in filteredNodes.enumerated() {
            visibleMap[flat.node.entry.id] = idx
        }

        var currentId: String? = entryId
        while let id = currentId {
            if let index = visibleMap[id] {
                return index
            }
            guard let entry = entryMap[id] else { break }
            currentId = parentId(for: entry)
        }

        return max(0, filteredNodes.count - 1)
    }

    private func parentId(for entry: SessionEntry) -> String? {
        switch entry {
        case .message(let entry):
            return entry.parentId
        case .thinkingLevel(let entry):
            return entry.parentId
        case .modelChange(let entry):
            return entry.parentId
        case .compaction(let entry):
            return entry.parentId
        case .branchSummary(let entry):
            return entry.parentId
        case .custom(let entry):
            return entry.parentId
        case .customMessage(let entry):
            return entry.parentId
        case .usage(let entry):
            return entry.parentId
        case .contextEdit(let entry):
            return entry.parentId
        case .label(let entry):
            return entry.parentId
        case .sessionInfo(let entry):
            return entry.parentId
        }
    }

    private static func flatten(_ roots: [SessionTreeNode]) -> [FlatNode] {
        var result: [FlatNode] = []
        var stack: [(node: SessionTreeNode, indent: Int)] = roots.map { ($0, 0) }.reversed()

        while let item = stack.popLast() {
            result.append(FlatNode(node: item.node, indent: item.indent))
            let children = item.node.children.reversed()
            for child in children {
                stack.append((child, item.indent + 1))
            }
        }

        return result
    }
}

private final class LabelInput: Container {
    private let input: Input
    let entryId: String
    var onSubmit: ((String, String?) -> Void)?
    var onCancel: (() -> Void)?

    init(entryId: String, currentLabel: String?) {
        self.entryId = entryId
        self.input = Input()
        super.init()

        addChild(Text(theme.fg(.muted, "  Label (empty to remove):"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        if let currentLabel {
            input.setValue(currentLabel)
        }
        addChild(input)
        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "  enter: save  esc: cancel"), paddingX: 1, paddingY: 0))
    }

    override func handleInput(_ keyData: String) {
        if isEnter(keyData) {
            let value = input.getValue().trimmingCharacters(in: .whitespacesAndNewlines)
            onSubmit?(entryId, value.isEmpty ? nil : value)
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancel?()
            return
        }
        input.handleInput(keyData)
    }
}

private final class SearchLine: Component {
    private let list: TreeList

    init(_ list: TreeList) {
        self.list = list
    }

    func render(width: Int) -> [String] {
        _ = list
        return [truncateToWidth(theme.fg(.muted, "  Search:"), maxWidth: width, ellipsis: "")]
    }
}

public final class TreeSelectorComponent: Container {
    private let treeList: TreeList
    private var labelInput: LabelInput?
    private let labelInputContainer: Container
    private let treeContainer: Container
    private let onLabelChangeCallback: ((String, String?) -> Void)?

    public init(
        tree: [SessionTreeNode],
        currentLeafId: String?,
        terminalHeight: Int,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onLabelChange: ((String, String?) -> Void)? = nil
    ) {
        let maxVisible = max(5, terminalHeight / 2)
        self.treeList = TreeList(tree: tree, currentLeafId: currentLeafId, maxVisibleLines: maxVisible)
        self.labelInputContainer = Container()
        self.treeContainer = Container()
        self.onLabelChangeCallback = onLabelChange

        super.init()

        treeList.onSelect = onSelect
        treeList.onCancel = onCancel
        treeList.onLabelEdit = { [weak self] entryId, label in
            self?.showLabelInput(entryId: entryId, currentLabel: label)
        }

        treeContainer.addChild(treeList)

        addChild(Spacer(1))
        addChild(DynamicBorder())
        addChild(Text(theme.bold("  Session Tree"), paddingX: 1, paddingY: 0))
        addChild(TruncatedText(theme.fg(.muted, "  ↑/↓: move. enter: select. l: label. Type to search"), paddingX: 0, paddingY: 0))
        addChild(SearchLine(treeList))
        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(treeContainer)
        addChild(labelInputContainer)
        addChild(Spacer(1))
        addChild(DynamicBorder())

        if tree.isEmpty {
            onCancel()
        }
    }

    private func showLabelInput(entryId: String, currentLabel: String?) {
        let labelInput = LabelInput(entryId: entryId, currentLabel: currentLabel)
        labelInput.onSubmit = { [weak self] id, label in
            self?.treeList.updateNodeLabel(id, label)
            self?.onLabelChangeCallback?(id, label)
            self?.hideLabelInput()
        }
        labelInput.onCancel = { [weak self] in
            self?.hideLabelInput()
        }

        self.labelInput = labelInput
        treeContainer.clear()
        labelInputContainer.clear()
        labelInputContainer.addChild(labelInput)
    }

    private func hideLabelInput() {
        labelInput = nil
        labelInputContainer.clear()
        treeContainer.clear()
        treeContainer.addChild(treeList)
    }

    public override func handleInput(_ keyData: String) {
        if let labelInput {
            labelInput.handleInput(keyData)
        } else {
            treeList.handleInput(keyData)
        }
    }

    public func getTreeList() -> Component {
        treeList
    }

    func getSelectedEntryId() -> String? {
        treeList.selectedEntryId()
    }
}

private func describeEntry(_ entry: SessionEntry) -> String {
    switch entry {
    case .message(let messageEntry):
        switch messageEntry.message {
        case .system:
            return theme.fg(.dim, "[system]")
        case .user(let user):
            return theme.fg(.accent, "user: ") + normalizeMessageText(extractUserText(user))
        case .assistant(let assistant):
            if assistant.stopReason == .aborted {
                return theme.fg(.success, "assistant: ") + theme.fg(.muted, "(aborted)")
            }
            if assistant.stopReason == .error {
                let err = assistant.errorMessage ?? "error"
                return theme.fg(.success, "assistant: ") + theme.fg(.error, err)
            }
            let text = extractAssistantText(assistant)
            if text.isEmpty {
                return theme.fg(.success, "assistant: ") + theme.fg(.muted, "(no content)")
            }
            return theme.fg(.success, "assistant: ") + normalizeMessageText(text)
        case .toolResult(let toolResult):
            let name = toolResult.toolName
            return theme.fg(.muted, "[\(name)]")
        case .custom(let custom):
            return theme.fg(.dim, "[\(custom.role)]")
        }
    case .compaction(let entry):
        return theme.fg(.borderAccent, "[compaction: \(entry.tokensBefore / 1000)k tokens]")
    case .branchSummary(let entry):
        return theme.fg(.warning, "[branch summary]: ") + normalizeMessageText(entry.summary)
    case .modelChange(let entry):
        return theme.fg(.dim, "[model: \(entry.modelId)]")
    case .thinkingLevel(let entry):
        return theme.fg(.dim, "[thinking: \(entry.thinkingLevel)]")
    case .custom(let entry):
        return theme.fg(.dim, "[custom: \(entry.customType)]")
    case .contextEdit(let entry):
        return theme.fg(.dim, "[context \(entry.replacement == nil ? "omit" : "replace"): \(entry.targetId)]")
    case .usage(let entry):
        return theme.fg(.dim, "[usage: \(entry.kind)]")
    case .customMessage(let entry):
        return theme.fg(.customMessageLabel, "[\(entry.customType)]: ") + normalizeMessageText(extractHookMessageText(entry.content))
    case .label(let entry):
        return theme.fg(.dim, "[label: \(entry.label ?? "(cleared)")] ")
    case .sessionInfo(let entry):
        return theme.fg(.dim, "[session name: \(entry.name ?? "(cleared)")]")
    }
}

private func extractUserText(_ message: UserMessage) -> String {
    switch message.content {
    case .text(let text):
        return text
    case .blocks(let blocks):
        return blocks.compactMap { block in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined(separator: "\n")
    }
}

private func extractAssistantText(_ message: AssistantMessage) -> String {
    return message.content.compactMap { block in
        if case let .text(text) = block {
            return text.text
        }
        return nil
    }.joined(separator: "\n")
}

private func extractHookMessageText(_ content: HookMessageContent) -> String {
    switch content {
    case .text(let text):
        return text
    case .blocks(let blocks):
        return blocks.compactMap { block in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined(separator: "\n")
    }
}

private func normalizeMessageText(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
