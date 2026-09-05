import MiniTui
import PiSwiftCodingAgent
import PiSwiftAgent

@MainActor
public final class ThinkingSelectorComponent: Container, MouseFocusOwner, Focusable, SystemCursorAware {
    private let searchInput = Input()
    private let listContainer = Container()
    private var selectList: SelectList
    private let allItems: [SelectItem]
    private let onSelect: (ThinkingLevel) -> Void
    private let onCancel: () -> Void
    private let onSelectAsDefault: ((ThinkingLevel) -> Void)?
    public var focused: Bool {
        get { searchInput.focused }
        set { searchInput.focused = newValue }
    }
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(currentLevel: ThinkingLevel, availableLevels: [ThinkingLevel],
                onSelect: @escaping (ThinkingLevel) -> Void, onCancel: @escaping () -> Void,
                onSelectAsDefault: ((ThinkingLevel) -> Void)? = nil,
                defaultThinkingLevel: ThinkingLevel? = nil, cycleKey: String = "Shift+Tab") {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onSelectAsDefault = onSelectAsDefault
        allItems = availableLevels.map { level in
            SelectItem(value: level.rawValue, label: (level == currentLevel ? "✓ " : "  ") + level.rawValue,
                       description: (thinkingDescriptions[level] ?? "") + (level == defaultThinkingLevel ? " · default" : ""))
        }
        selectList = SelectList(items: [], maxVisible: 1, theme: getSelectListTheme())
        super.init()
        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text("Thinking Level", paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        addChild(Text("\(cycleKey) cycles thinking levels in-session", paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        searchInput.onSubmit = { [weak self] _ in self?.selectList.handleInput("\r") }
        addChild(searchInput)
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "  Enter to select · Ctrl+S to set as default · Esc to cancel"), paddingX: 0, paddingY: 0))
        addChild(DynamicBorder())
        rebuild(allItems, preselect: currentLevel.rawValue)
    }

    private func rebuild(_ items: [SelectItem], preselect: String?) {
        selectList = SelectList(items: items, maxVisible: max(1, items.count), theme: getSelectListTheme(),
                                layoutOptions: SelectListLayoutOptions(minPrimaryColumnWidth: 12, maxPrimaryColumnWidth: 32))
        if let index = items.firstIndex(where: { $0.value == preselect }) { selectList.setSelectedIndex(index) }
        selectList.onSelect = { [weak self] item in
            if let level = ThinkingLevel(rawValue: item.value) { self?.onSelect(level) }
        }
        selectList.onCancel = onCancel
        listContainer.clear()
        listContainer.addChild(selectList)
    }

    public override func handleInput(_ data: String) {
        if matchesKey(data, Key.ctrl("s")), let onSelectAsDefault {
            if let item = selectList.getSelectedItem(), let level = ThinkingLevel(rawValue: item.value) { onSelectAsDefault(level) }
            return
        }
        if isSelectNavigation(data) { selectList.handleInput(data); return }
        searchInput.handleInput(data)
        let query = searchInput.getValue()
        let items = query.isEmpty ? allItems : fuzzyFilter(allItems, query) { "\($0.value) \($0.description ?? "")" }
        rebuild(items, preselect: selectList.getSelectedItem()?.value)
    }

    public func getSelectList() -> SelectList { selectList }
}
