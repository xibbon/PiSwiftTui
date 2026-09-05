import MiniTui
import PiSwiftCodingAgent

@MainActor
func isSelectNavigation(_ data: String) -> Bool {
    let kb = getKeybindings()
    return [TUIKeybinding.selectUp, TUIKeybinding.selectDown, TUIKeybinding.selectConfirm, TUIKeybinding.selectCancel]
        .contains { kb.matches(data, $0) }
}

@MainActor
public final class SelectSubmenu: Container, MouseFocusOwner, SystemCursorAware, Focusable {
    public var usesSystemCursor: Bool {
        get { searchInput?.usesSystemCursor ?? false }
        set { searchInput?.usesSystemCursor = newValue }
    }
    public var focused: Bool {
        get { searchInput?.focused ?? false }
        set { searchInput?.focused = newValue }
    }
    private let allOptions: [SelectItem]
    private let layout: SelectListLayoutOptions
    private let onSelect: (String) -> Void
    private let onCancel: () -> Void
    private let onSelectionChange: ((String) -> Void)?
    private let searchInput: Input?
    private let listContainer = Container()
    private var selectList: SelectList

    public init(title: String, description: String, options: [SelectItem], currentValue: String,
                onSelect: @escaping (String) -> Void, onCancel: @escaping () -> Void,
                onSelectionChange: ((String) -> Void)? = nil, searchable: Bool = false,
                layout: SelectListLayoutOptions = SelectListLayoutOptions(minPrimaryColumnWidth: 12, maxPrimaryColumnWidth: 32)) {
        allOptions = options
        self.layout = layout
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onSelectionChange = onSelectionChange
        searchInput = searchable ? Input() : nil
        selectList = SelectList(items: [], maxVisible: 1, theme: getSelectListTheme())
        super.init()
        addChild(Text(theme.bold(theme.fg(.accent, title)), paddingX: 0, paddingY: 0))
        if !description.isEmpty {
            addChild(Spacer(1))
            addChild(Text(theme.fg(.muted, description), paddingX: 0, paddingY: 0))
        }
        if let searchInput {
            addChild(Spacer(1))
            searchInput.onSubmit = { [weak self] _ in self?.selectList.handleInput("\r") }
            addChild(searchInput)
        }
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        let hint = searchable ? "  Type to filter · Enter to select · Esc to go back" : "  Enter to select · Esc to go back"
        addChild(Text(theme.fg(.dim, hint), paddingX: 0, paddingY: 0))
        rebuild(options, preselect: currentValue)
    }

    private func rebuild(_ options: [SelectItem], preselect: String) {
        selectList = SelectList(items: options, maxVisible: max(1, min(options.count, 10)), theme: getSelectListTheme(), layoutOptions: layout)
        if let index = options.firstIndex(where: { $0.value == preselect }) { selectList.setSelectedIndex(index) }
        selectList.onSelect = { [weak self] in self?.onSelect($0.value) }
        selectList.onCancel = onCancel
        selectList.onSelectionChange = { [weak self] in self?.onSelectionChange?($0.value) }
        listContainer.clear()
        listContainer.addChild(selectList)
    }

    public override func handleInput(_ data: String) {
        guard let searchInput, !isSelectNavigation(data) else { selectList.handleInput(data); return }
        searchInput.handleInput(data)
        let query = searchInput.getValue()
        rebuild(query.isEmpty ? allOptions : fuzzyFilter(allOptions, query) { "\($0.label) \($0.description ?? "")" }, preselect: "")
    }
}

@MainActor
public struct SteppedSubmenuStep {
    public var key: String
    public var title: ([String: String]) -> String
    public var description: ([String: String]) -> String
    public var options: ([String: String]) -> [SelectItem]
    public var preselect: ([String: String]) -> String?
    public var searchable: Bool
    public var layout: SelectListLayoutOptions
    public init(key: String, title: @escaping ([String: String]) -> String,
                description: @escaping ([String: String]) -> String,
                options: @escaping ([String: String]) -> [SelectItem],
                preselect: @escaping ([String: String]) -> String? = { _ in nil }, searchable: Bool = false,
                layout: SelectListLayoutOptions = SelectListLayoutOptions(minPrimaryColumnWidth: 12, maxPrimaryColumnWidth: 32)) {
        self.key = key; self.title = title; self.description = description; self.options = options
        self.preselect = preselect; self.searchable = searchable; self.layout = layout
    }
}

@MainActor
public final class SteppedSubmenu: Container, MouseFocusOwner, SystemCursorAware, Focusable {
    public var usesSystemCursor = false { didSet { active?.usesSystemCursor = usesSystemCursor } }
    public var focused = false { didSet { active?.focused = focused } }
    private let steps: [SteppedSubmenuStep]
    private let onComplete: ([String: String]) -> Void
    private let onCancel: () -> Void
    private let loop: Bool
    private var context: [String: String]
    private var active: SelectSubmenu?

    public init(steps: [SteppedSubmenuStep], onComplete: @escaping ([String: String]) -> Void,
                onCancel: @escaping () -> Void, startAtStep: Int = 0,
                initialContext: [String: String] = [:], loop: Bool = false) {
        precondition(!steps.isEmpty && steps.indices.contains(startAtStep))
        self.steps = steps; self.onComplete = onComplete; self.onCancel = onCancel
        self.context = initialContext; self.loop = loop
        super.init()
        showStep(startAtStep)
    }

    private func showStep(_ index: Int) {
        let step = steps[index]
        let stepLabel = steps.count > 1 ? "Step \(index + 1)/\(steps.count) · " : ""
        active = SelectSubmenu(title: step.title(context), description: stepLabel + step.description(context),
            options: step.options(context), currentValue: step.preselect(context) ?? "", onSelect: { [weak self] value in
                guard let self else { return }
                context[step.key] = value
                if index + 1 < steps.count { showStep(index + 1) } else {
                    onComplete(context)
                    if loop { context = [:]; showStep(0) } else { onCancel() }
                }
            }, onCancel: { [weak self] in
                guard let self else { return }
                if index > 0 { context.removeValue(forKey: step.key); showStep(index - 1) } else { onCancel() }
            }, searchable: step.searchable, layout: step.layout)
        active?.usesSystemCursor = usesSystemCursor
        active?.focused = focused
        clear()
        if let active { addChild(active) }
    }
    public override func handleInput(_ data: String) { active?.handleInput(data) }
}
