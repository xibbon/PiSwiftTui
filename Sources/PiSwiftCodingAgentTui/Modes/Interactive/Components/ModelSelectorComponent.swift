import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public struct ModelSelection: Sendable, Equatable {
    public let provider: String
    public let id: String
    public init(provider: String, id: String) { self.provider = provider; self.id = id }
}

private struct ModelItem {
    let provider: String
    let id: String
    let model: Model
}

private struct ScopedModelItem {
    let model: Model
    let thinkingLevel: String
}

@MainActor
public final class ModelSelectorComponent: Container, MouseFocusOwner, SystemCursorAware, Focusable, SelectorClosable {
    private let searchInput: Input
    private let listContainer: Container
    private var allModels: [ModelItem] = []
    private var scopedModelItems: [ModelItem] = []
    private var isScoped: Bool
    private var activeModels: [ModelItem] { isScoped ? scopedModelItems : allModels }
    private let scopeText = Text("", paddingX: 0, paddingY: 0)
    private var filteredModels: [ModelItem] = []
    private var selectedIndex = 0
    private let currentModel: Model?
    private let defaultModel: ModelSelection?
    private let onSelectAsDefaultCallback: ((Model) -> Void)?
    public var focused: Bool {
        get { searchInput.focused }
        set { searchInput.focused = newValue }
    }
    private let modelRegistry: ModelRegistry
    private let onSelectCallback: (Model) -> Void
    private let onCancelCallback: () -> Void
    private var errorMessage: String?
    /// Success/progress line for the background catalog refresh; never an error.
    private var refreshStatusMessage: String?
    /// Cancels the background refresh when the selector closes (#7153).
    private let refreshSignal = CancellationToken()
    private var closed = false
    private let tui: TUI
    private let scopedModels: [ScopedModelItem]
    private let initialSearchInput: String?
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(
        tui: TUI,
        currentModel: Model?,
        defaultModel: ModelSelection? = nil,
        modelRegistry: ModelRegistry,
        scopedModels: [ScopedModel],
        onSelect: @escaping (Model) -> Void,
        onCancel: @escaping () -> Void,
        initialSearchInput: String? = nil,
        onSelectAsDefault: ((Model) -> Void)? = nil
    ) {
        self.isScoped = !scopedModels.isEmpty
        self.tui = tui
        self.currentModel = currentModel
        self.defaultModel = defaultModel
        self.onSelectAsDefaultCallback = onSelectAsDefault
        self.modelRegistry = modelRegistry
        self.scopedModels = scopedModels.map { ScopedModelItem(model: $0.model, thinkingLevel: ($0.thinkingLevel ?? .off).rawValue) }
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.initialSearchInput = initialSearchInput

        self.searchInput = Input()
        if let initialSearchInput, !initialSearchInput.isEmpty {
            self.searchInput.setValue(initialSearchInput)
        }
        self.listContainer = Container()

        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))

        let hintText = scopedModels.isEmpty
            ? "Only showing models with configured API keys (see README for details)"
            : "Showing models from --models scope"
        addChild(Text(theme.fg(.warning, hintText), paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        if !scopedModels.isEmpty {
            addChild(scopeText)
            addChild(Text(theme.fg(.muted, "Tab scope (all/scoped)"), paddingX: 0, paddingY: 0))
            addChild(Spacer(1))
        }

        searchInput.onSubmit = { [weak self] _ in
            guard let self else { return }
            if let selected = self.filteredModels[safe: self.selectedIndex] {
                self.handleSelect(selected.model)
            }
        }
        addChild(searchInput)
        addChild(Spacer(1))

        addChild(listContainer)
        addChild(Spacer(1))
        if onSelectAsDefault != nil {
            addChild(Text(theme.fg(.dim, "  \(formatKeys(getKeybindings().getKeys(TUIKeybinding.selectConfirm))) to select · \(selectorKeyText("app.models.save")) to set as default · \(formatKeys(getKeybindings().getKeys(TUIKeybinding.selectCancel))) to cancel"), paddingX: 0, paddingY: 0))
        }
        addChild(DynamicBorder())

        loadModels()
    }

    /// Renders whatever is already cached, then — for the unscoped picker — refreshes the
    /// catalogs in the background (#7443, #7153). Opening the picker never blocks on the network.
    private func loadModels() {
        scopedModelItems = scopedModels.map { ModelItem(provider: $0.model.provider, id: $0.model.id, model: $0.model) }
        selectedIndex = activeModels.firstIndex { modelsAreEqual(currentModel, $0.model) } ?? 0
        filterModels(searchInput.getValue())
        updateScopeText()
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            await loadModelsFromSnapshot()
            guard !closed else { return }
            await refreshModels()
        }
    }

    private func loadModelsFromSnapshot(adoptRegistryError: Bool = true) async {
        if adoptRegistryError { errorMessage = modelRegistry.getError() }
        var items = await modelRegistry.getAvailable().map { ModelItem(provider: $0.provider, id: $0.id, model: $0) }
        scopedModelItems = scopedModels.map { scoped in
            let model = modelRegistry.find(scoped.model.provider, scoped.model.id) ?? scoped.model
            return ModelItem(provider: model.provider, id: model.id, model: model)
        }
        items.sort { lhs, rhs in
            let lhsCurrent = modelsAreEqual(currentModel, lhs.model)
            let rhsCurrent = modelsAreEqual(currentModel, rhs.model)
            if lhsCurrent != rhsCurrent {
                return lhsCurrent
            }
            let lhsDefault = isDefaultModel(lhs.model)
            let rhsDefault = isDefaultModel(rhs.model)
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
        }

        allModels = items
        selectedIndex = activeModels.firstIndex { modelsAreEqual(currentModel, $0.model) } ?? min(selectedIndex, max(0, activeModels.count - 1))
        filterModels(searchInput.getValue())
        updateScopeText()
        tui.requestRender()
    }

    /// Background catalog refresh with its own cancellation token, bounded by the shared timeout.
    /// The cached list stays on screen throughout; only the status line changes.
    private func refreshModels() async {
        let outcome = await runBoundedCatalogRefresh(registry: modelRegistry, signal: refreshSignal)
        guard !closed else { return }

        refreshStatusMessage = nil
        if let message = CatalogRefreshStatus.selectorMessage(outcome) {
            errorMessage = message
        } else {
            errorMessage = modelRegistry.getError()
            if errorMessage == nil {
                refreshStatusMessage = "Model catalogs refreshed."
            }
        }

        await loadModelsFromSnapshot(adoptRegistryError: false)
    }

    /// Cancels the in-flight refresh. Called when the selector closes (#7153).
    public func closeSelector() {
        guard !closed else { return }
        closed = true
        refreshSignal.cancel()
    }

    private func filterModels(_ query: String) {
        filteredModels = query.isEmpty ? activeModels : fuzzyFilter(activeModels, query) { "\($0.id) \($0.provider) \($0.model.name)\(isDefaultModel($0.model) ? " default" : "")" }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty && "default".hasPrefix(normalized) {
            filteredModels = activeModels.filter { isDefaultModel($0.model) } + filteredModels.filter { !isDefaultModel($0.model) }
        }
        selectedIndex = query.isEmpty ? min(selectedIndex, max(0, filteredModels.count - 1)) : 0
        updateList()
    }

    private func updateList() {
        listContainer.clear()

        let maxVisible = 10
        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredModels.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredModels.count)

        for i in startIndex..<endIndex {
            let item = filteredModels[i]
            let isSelected = i == selectedIndex
            let isCurrent = modelsAreEqual(currentModel, item.model)

            let modelText = item.id
            let providerBadge = theme.fg(.muted, "[\(item.provider)]")
            let checkmark = isCurrent ? theme.fg(.accent, "✓ ") : "  "
            let prefix = isSelected ? theme.fg(.accent, "→ ") : "  "
            let badge = isDefaultModel(item.model) ? theme.fg(.muted, " · default") : ""
            let line = "\(prefix)\(checkmark)\(isSelected ? theme.fg(.accent, modelText) : modelText) \(providerBadge)\(badge)"

            listContainer.addChild(Text(line, paddingX: 0, paddingY: 0))
        }

        if startIndex > 0 || endIndex < filteredModels.count {
            let scrollInfo = theme.fg(.muted, "  (\(selectedIndex + 1)/\(filteredModels.count))")
            listContainer.addChild(Text(scrollInfo, paddingX: 0, paddingY: 0))
        }

        if let errorMessage {
            for line in errorMessage.split(separator: "\n", omittingEmptySubsequences: false) {
                listContainer.addChild(Text(theme.fg(.error, String(line)), paddingX: 0, paddingY: 0))
            }
        } else if let refreshStatusMessage {
            listContainer.addChild(Text(theme.fg(.success, refreshStatusMessage), paddingX: 0, paddingY: 0))
        } else if filteredModels.isEmpty {
            listContainer.addChild(Text(theme.fg(.muted, "  No matching models"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ keyData: String) {
        if selectorKeyMatches(keyData, "app.models.save"), let onSelectAsDefaultCallback {
            if let selected = filteredModels[safe: selectedIndex] { closeSelector(); onSelectAsDefaultCallback(selected.model) }
            return
        }
        let kb = getKeybindings()
        if kb.matches(keyData, TUIKeybinding.inputTab) {
            if !scopedModelItems.isEmpty {
                isScoped.toggle()
                selectedIndex = activeModels.firstIndex { modelsAreEqual(currentModel, $0.model) } ?? 0
                filterModels(searchInput.getValue())
                updateScopeText()
            }
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectUp) {
            guard !filteredModels.isEmpty else { return }
            selectedIndex = selectedIndex == 0 ? filteredModels.count - 1 : selectedIndex - 1
            updateList()
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectDown) {
            guard !filteredModels.isEmpty else { return }
            selectedIndex = selectedIndex == filteredModels.count - 1 ? 0 : selectedIndex + 1
            updateList()
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectConfirm) {
            if let selected = filteredModels[safe: selectedIndex] {
                handleSelect(selected.model)
            }
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectCancel) {
            closeSelector()
            onCancelCallback()
            return
        }

        searchInput.handleInput(keyData)
        filterModels(searchInput.getValue())
    }

    private func updateScopeText() {
        scopeText.setText(theme.fg(.muted, "Scope: ") + theme.fg(isScoped ? .muted : .accent, "all") + theme.fg(.muted, " | ") + theme.fg(isScoped ? .accent : .muted, "scoped"))
    }

    private func isDefaultModel(_ model: Model) -> Bool {
        defaultModel?.provider == model.provider && defaultModel?.id == model.id
    }

    private func handleSelect(_ model: Model) {
        closeSelector()
        onSelectCallback(model)
    }

    public func getSearchInput() -> Input {
        searchInput
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
