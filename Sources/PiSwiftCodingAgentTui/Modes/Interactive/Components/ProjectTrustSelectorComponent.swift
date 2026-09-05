import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class ProjectTrustSelectorComponent: Container, MouseFocusOwner {
    private let savedDecision: ProjectTrustUpdate?
    private let cwd: String
    private let options: [ProjectTrustOption]
    private var selectedIndex = 0
    private let listContainer: Container
    private let onSelectCallback: (ProjectTrustOption) -> Void
    private let onCancelCallback: () -> Void

    public init(
        cwd: String,
        options: [ProjectTrustOption],
        onSelect: @escaping (ProjectTrustOption) -> Void,
        onCancel: @escaping () -> Void,
        savedDecision: ProjectTrustUpdate? = nil,
        projectTrusted: Bool? = nil
    ) {
        self.savedDecision = savedDecision
        self.cwd = cwd
        self.options = options
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.listContainer = Container()
        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, "Project trust required"), paddingX: 1, paddingY: 0))
        addChild(Text(theme.fg(.muted, cwd), paddingX: 1, paddingY: 0))
        if let projectTrusted {
            let saved = savedDecision.map { "\($0.decision == true ? "trusted" : "untrusted") (\($0.path))" } ?? "none"
            addChild(Text(theme.fg(.muted, "Saved decision: \(saved)\nCurrent session: \(projectTrusted ? "trusted" : "untrusted")"), paddingX: 1, paddingY: 0))
        }
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "up/down navigate  enter select  esc cancel"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())

        if let savedDecision {
            selectedIndex = options.firstIndex { $0.savedPath == savedDecision.path && $0.trusted == savedDecision.decision } ?? 0
        }
        updateList()
    }

    private func updateList() {
        listContainer.clear()
        for (index, option) in options.enumerated() {
            let isSelected = index == selectedIndex
            let prefix = isSelected ? "→ " : "  "
            let current = option.savedPath != nil && option.savedPath == savedDecision?.path && option.trusted == savedDecision?.decision
            let marker = current ? theme.fg(.accent, "✓ ") : "  "
            let line = isSelected
                ? theme.fg(.accent, prefix + marker + option.label)
                : prefix + marker + theme.fg(.text, option.label)
            listContainer.addChild(Text(line, paddingX: 1, paddingY: 0))
        }
    }

    public override func handleInput(_ keyData: String) {
        if isArrowUp(keyData) || keyData == "k" {
            selectedIndex = max(0, selectedIndex - 1)
            updateList()
            return
        }
        if isArrowDown(keyData) || keyData == "j" {
            selectedIndex = min(options.count - 1, selectedIndex + 1)
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
