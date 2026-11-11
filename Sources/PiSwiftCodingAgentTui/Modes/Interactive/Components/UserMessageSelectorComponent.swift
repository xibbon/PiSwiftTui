import Foundation
import MiniTui
import PiSwiftCodingAgent

private struct UserMessageItem {
    let id: String
    let text: String
    let timestamp: String?
}

private final class UserMessageList: Component {
    var capturesViewportInput: Bool { true }
    private let messages: [UserMessageItem]
    private var selectedIndex: Int
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let maxVisible = 10

    init(messages: [UserMessageItem]) {
        self.messages = messages
        self.selectedIndex = max(0, messages.count - 1)
    }

    func invalidate() {}

    func render(width: Int) -> [String] {
        var lines: [String] = []
        if messages.isEmpty {
            lines.append(theme.fg(.muted, "  No user messages found"))
            return lines
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, messages.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, messages.count)

        for i in startIndex..<endIndex {
            let message = messages[i]
            let isSelected = i == selectedIndex
            let normalized = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            let cursor = isSelected ? theme.fg(.accent, "› ") : "  "
            let maxWidth = width - 2
            let truncated = truncateToWidth(normalized, maxWidth: maxWidth, ellipsis: "...")
            let line = cursor + (isSelected ? theme.bold(truncated) : truncated)
            lines.append(line)

            let metadata = "  Message \(i + 1) of \(messages.count)"
            lines.append(theme.fg(.muted, metadata))
            lines.append("")
        }

        if startIndex > 0 || endIndex < messages.count {
            let scrollInfo = theme.fg(.muted, "  (\(selectedIndex + 1)/\(messages.count))")
            lines.append(scrollInfo)
        }

        return lines
    }

    func handleInput(_ keyData: String) {
        if let index = getSelectPageIndex(keybindings: getKeybindings(), data: keyData, selectedIndex: selectedIndex, itemCount: messages.count, pageSize: maxVisible) {
            guard !messages.isEmpty else { return }
            selectedIndex = index
            return
        }
        if isArrowUp(keyData) {
            selectedIndex = selectedIndex == 0 ? messages.count - 1 : selectedIndex - 1
            return
        }
        if isArrowDown(keyData) {
            selectedIndex = selectedIndex == messages.count - 1 ? 0 : selectedIndex + 1
            return
        }
        if isEnter(keyData) {
            if let selected = messages[safe: selectedIndex] {
                onSelect?(selected.id)
            }
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancel?()
        }
    }
}

public final class UserMessageSelectorComponent: Container {
    public override var capturesViewportInput: Bool { true }
    public override func handleInput(_ data: String) { messageList.handleInput(data) }
    private let messageList: UserMessageList

    public init(messages: [(id: String, text: String, timestamp: String?)], onSelect: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        let items = messages.map { UserMessageItem(id: $0.id, text: $0.text, timestamp: $0.timestamp) }
        self.messageList = UserMessageList(messages: items)
        super.init()

        addChild(Spacer(1))
        addChild(Text(theme.bold("Branch from Message"), paddingX: 1, paddingY: 0))
        addChild(Text(theme.fg(.muted, "Select a message to create a new branch from that point"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())
        addChild(Spacer(1))

        messageList.onSelect = onSelect
        messageList.onCancel = onCancel
        addChild(messageList)

        addChild(Spacer(1))
        addChild(DynamicBorder())

        if messages.isEmpty {
            onCancel()
        }
    }

    public func getMessageList() -> Component {
        messageList
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
