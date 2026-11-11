import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class HookSelectorComponent: Container {
    public override var capturesViewportInput: Bool { true }
    private let options: [String]
    private var selectedIndex = 0
    private let listContainer: Container
    private let onSelectCallback: (String) -> Void
    private let onCancelCallback: () -> Void

    public init(
        title: String,
        options: [String],
        description: String? = nil,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.options = options
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.listContainer = Container()
        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, title), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        if let description, !description.isEmpty {
            addChild(Text(theme.fg(.dim, description), paddingX: 1, paddingY: 0))
            addChild(Spacer(1))
        }

        addChild(listContainer)

        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "↑↓ navigate  enter select  esc cancel"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())

        updateList()
    }

    private func updateList() {
        listContainer.clear()
        let maxVisible = 10
        let start = max(0, min(selectedIndex - maxVisible / 2, options.count - maxVisible))
        let end = min(start + maxVisible, options.count)
        for index in start..<end {
            let option = options[index]
            let isSelected = index == selectedIndex
            let line = isSelected
                ? theme.fg(.accent, "→ ") + theme.fg(.accent, option)
                : "  \(theme.fg(.text, option))"
            listContainer.addChild(Text(line, paddingX: 1, paddingY: 0))
        }
        if start > 0 || end < options.count {
            listContainer.addChild(Text(theme.fg(.muted, "  (\(selectedIndex + 1)/\(options.count))"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ keyData: String) {
        if let index = getSelectPageIndex(keybindings: getKeybindings(), data: keyData,
            selectedIndex: selectedIndex, itemCount: options.count, pageSize: 10) {
            selectedIndex = index
            updateList()
            return
        }
        if isArrowUp(keyData) || keyData == "k" {
            selectedIndex = max(0, selectedIndex - 1)
            updateList()
            return
        }
        if isArrowDown(keyData) || keyData == "j" {
            selectedIndex = min(max(0, options.count - 1), selectedIndex + 1)
            updateList()
            return
        }
        if isEnter(keyData) || keyData == "\n" {
            if let selected = options[safe: selectedIndex] {
                onSelectCallback(selected)
            }
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
