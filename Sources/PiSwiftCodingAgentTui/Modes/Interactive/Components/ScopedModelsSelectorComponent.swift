import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

private typealias EnabledIds = [String]?

private func isEnabled(_ enabledIds: EnabledIds, _ id: String) -> Bool {
    enabledIds == nil || enabledIds?.contains(id) == true
}

private func normalizeEnabled(_ ids: [String], _ allIds: [String]) -> EnabledIds {
    ids.count == allIds.count && ids.allSatisfy { allIds.contains($0) } ? nil : ids
}

private func toggle(_ enabledIds: EnabledIds, _ allIds: [String], _ id: String) -> EnabledIds {
    guard var enabledIds else { return allIds.filter { $0 != id } }
    if let index = enabledIds.firstIndex(of: id) {
        enabledIds.remove(at: index)
    } else {
        enabledIds.append(id)
    }
    return normalizeEnabled(enabledIds, allIds)
}

private func enableAll(_ enabledIds: EnabledIds, _ allIds: [String], targetIds: [String]? = nil) -> EnabledIds {
    guard var enabledIds else { return nil }
    let targets = targetIds ?? allIds
    for id in targets where !enabledIds.contains(id) {
        enabledIds.append(id)
    }
    return normalizeEnabled(enabledIds, allIds)
}

private func clearAll(_ enabledIds: EnabledIds, _ allIds: [String], targetIds: [String]? = nil) -> EnabledIds {
    if enabledIds == nil {
        if let targetIds {
            return allIds.filter { !targetIds.contains($0) }
        }
        return []
    }
    let targets = Set(targetIds ?? enabledIds ?? [])
    return enabledIds?.filter { !targets.contains($0) }
}

private func move(_ enabledIds: EnabledIds, _ allIds: [String], _ id: String, delta: Int) -> EnabledIds {
    var list = enabledIds ?? allIds
    guard let index = list.firstIndex(of: id) else { return list }
    let newIndex = index + delta
    guard newIndex >= 0 && newIndex < list.count else { return list }
    list.swapAt(index, newIndex)
    return list
}

private func getSortedIds(_ enabledIds: EnabledIds, _ allIds: [String]) -> [String] {
    guard let enabledIds else { return allIds }
    let enabledSet = Set(enabledIds)
    return enabledIds + allIds.filter { !enabledSet.contains($0) }
}

private struct ModelItem {
    let fullId: String
    let model: Model?
    let enabled: Bool
}

public struct ModelsConfig: Sendable {
    public var allModels: [Model]
    public var enabledModelIds: [String]
    public var hasEnabledModelsFilter: Bool
    /// Shown while the background catalog refresh is in flight.
    public var refreshStatus: String?

    public init(
        allModels: [Model],
        enabledModelIds: [String],
        hasEnabledModelsFilter: Bool,
        refreshStatus: String? = nil
    ) {
        self.allModels = allModels
        self.enabledModelIds = enabledModelIds
        self.hasEnabledModelsFilter = hasEnabledModelsFilter
        self.refreshStatus = refreshStatus
    }
}

public struct ModelsCallbacks {
    public var onChange: ([String]?) -> Void
    public var onPersist: ([String]?) -> Void
    public var onCancel: () -> Void

    public init(onChange: @escaping ([String]?) -> Void,
                onPersist: @escaping ([String]?) -> Void,
                onCancel: @escaping () -> Void) {
        self.onChange = onChange
        self.onPersist = onPersist
        self.onCancel = onCancel
    }
}

@MainActor
public final class ScopedModelsSelectorComponent: Container, MouseFocusOwner, SystemCursorAware, Focusable, SelectorClosable {
    private var modelsById: [String: Model] = [:]
    private var allIds: [String] = []
    private var enabledIds: EnabledIds = nil
    private var filteredItems: [ModelItem] = []
    private var selectedIndex = 0
    private let searchInput: Input
    private let listContainer: Container
    private let footerText: Text
    private let statusText: Text
    private let callbacks: ModelsCallbacks
    private let maxVisible = 15
    private var isDirty = false
    /// Cancels the background catalog refresh when the selector closes (#7153).
    public let refreshSignal = CancellationToken()
    private var closed = false
    public var focused: Bool {
        get { searchInput.focused }
        set { searchInput.focused = newValue }
    }
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(config: ModelsConfig, callbacks: ModelsCallbacks) {
        self.callbacks = callbacks

        for model in config.allModels {
            let fullId = "\(model.provider)/\(model.id)"
            modelsById[fullId] = model
            allIds.append(fullId)
        }

        enabledIds = config.hasEnabledModelsFilter ? config.enabledModelIds : nil
        filteredItems = []

        searchInput = Input()
        listContainer = Container()
        footerText = Text("", paddingX: 0, paddingY: 0)
        statusText = Text(config.refreshStatus.map { theme.fg(.muted, $0) } ?? "", paddingX: 0, paddingY: 0)

        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, theme.bold("Model Configuration")), paddingX: 0, paddingY: 0))
        addChild(Text(theme.fg(.muted, "Session-only. \(selectorKeyText("app.models.save")) to save to settings."), paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        addChild(searchInput)
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(statusText)
        addChild(footerText)
        addChild(DynamicBorder())

        refresh()
    }

    /// Replaces the model set after a background catalog refresh. `enabledModelIds` is supplied
    /// only when the caller recomputed the enabled scope; otherwise the current scope is kept.
    public func updateModels(_ models: [Model], enabledModelIds: [String]?? = nil) {
        let selectedId = filteredItems[safe: selectedIndex]?.fullId
        modelsById = [:]
        allIds = []
        for model in models {
            let fullId = "\(model.provider)/\(model.id)"
            modelsById[fullId] = model
            allIds.append(fullId)
        }
        if let enabledModelIds {
            enabledIds = enabledModelIds
        }
        refresh()
        if let index = filteredItems.firstIndex(where: { $0.fullId == selectedId }) {
            selectedIndex = index
            updateList()
        }
    }

    public func setRefreshStatus(_ message: String, isError: Bool) {
        statusText.setText(theme.fg(isError ? .warning : .success, message))
    }

    public func clearRefreshStatus() {
        statusText.setText("")
    }

    /// Cancels the in-flight catalog refresh when the selector leaves the screen (#7153).
    public func closeSelector() {
        guard !closed else { return }
        closed = true
        refreshSignal.cancel()
    }

    public var isClosed: Bool { closed }

    private func buildItems() -> [ModelItem] {
        getSortedIds(enabledIds, allIds).map { id in
            return ModelItem(fullId: id, model: modelsById[id], enabled: isEnabled(enabledIds, id))
        }
    }

    private func getFooterText() -> String {
        let enabledCount = enabledIds?.count ?? allIds.count
        let allEnabled = enabledIds == nil
        let unavailable = enabledIds?.filter { modelsById[$0] == nil }.count ?? 0
        let countText = allEnabled ? "all enabled" : "\(enabledCount)/\(allIds.count) enabled\(unavailable > 0 ? " · \(unavailable) unavailable" : "")"
        let parts = ["\(formatKeys(getKeybindings().getKeys(TUIKeybinding.selectConfirm))) toggle", "\(selectorKeyText("app.models.enableAll")) all", "\(selectorKeyText("app.models.clearAll")) clear", "\(selectorKeyText("app.models.toggleProvider")) provider", "\(selectorKeyText("app.models.reorderUp"))/\(selectorKeyText("app.models.reorderDown")) reorder", "\(selectorKeyText("app.models.save")) save", countText]
        let hint = theme.fg(.dim, "  \(parts.joined(separator: " · "))")
        if isDirty {
            return hint + theme.fg(.warning, " (unsaved)")
        }
        return hint
    }

    private func refresh() {
        let query = searchInput.getValue()
        let items = buildItems()
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = fuzzyFilter(items, query: query) { "\($0.fullId) \($0.model?.name ?? "")" }
        }
        selectedIndex = min(selectedIndex, max(0, filteredItems.count - 1))
        updateList()
        footerText.setText(getFooterText())
    }

    private func updateList() {
        listContainer.clear()

        if filteredItems.isEmpty {
            listContainer.addChild(Text(theme.fg(.muted, "  No matching models"), paddingX: 0, paddingY: 0))
            return
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredItems.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredItems.count)
        for i in startIndex..<endIndex {
            let item = filteredItems[i]
            let isSelected = i == selectedIndex
            let prefix = isSelected ? theme.fg(.accent, "→ ") : "  "
            let id = item.model?.id ?? item.fullId
            let styledId = item.model == nil ? theme.strikethrough(id) : id
            let modelText = isSelected ? theme.fg(.accent, styledId) : styledId
            let providerBadge = theme.fg(.muted, item.model.map { " [\($0.provider)]" } ?? " [unavailable]")
            let status = item.model != nil && item.enabled ? theme.fg(.accent, "✓ ") : "  "
            listContainer.addChild(Text("\(prefix)\(status)\(modelText)\(providerBadge)", paddingX: 0, paddingY: 0))
        }

        if startIndex > 0 || endIndex < filteredItems.count {
            listContainer.addChild(Text(theme.fg(.muted, "  (\(selectedIndex + 1)/\(filteredItems.count))"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ data: String) {
        let kb = getKeybindings()

        if kb.matches(data, TUIKeybinding.selectUp) {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = selectedIndex == 0 ? filteredItems.count - 1 : selectedIndex - 1
            updateList()
            return
        }
        if kb.matches(data, TUIKeybinding.selectDown) {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = selectedIndex == filteredItems.count - 1 ? 0 : selectedIndex + 1
            updateList()
            return
        }

        if selectorKeyMatches(data, "app.models.reorderUp") || selectorKeyMatches(data, "app.models.reorderDown") {
            guard enabledIds != nil, let item = filteredItems[safe: selectedIndex], isEnabled(enabledIds, item.fullId) else { return }
            let delta = selectorKeyMatches(data, "app.models.reorderUp") ? -1 : 1
            let enabledList = enabledIds ?? allIds
            guard let currentIndex = enabledList.firstIndex(of: item.fullId) else { return }
            let newIndex = currentIndex + delta
            guard newIndex >= 0 && newIndex < enabledList.count else { return }
            enabledIds = move(enabledIds, allIds, item.fullId, delta: delta)
            isDirty = true
            selectedIndex += delta
            refresh()
            callbacks.onChange(enabledIds)
            return
        }

        if kb.matches(data, TUIKeybinding.selectConfirm) {
            guard let item = filteredItems[safe: selectedIndex] else { return }
            enabledIds = toggle(enabledIds, allIds, item.fullId)
            isDirty = true
            callbacks.onChange(enabledIds)
            refresh()
            return
        }

        if selectorKeyMatches(data, "app.models.enableAll") {
            let targetIds = searchInput.getValue().isEmpty ? nil : filteredItems.map { $0.fullId }
            enabledIds = enableAll(enabledIds, allIds, targetIds: targetIds)
            isDirty = true
            callbacks.onChange(enabledIds)
            refresh()
            return
        }

        if selectorKeyMatches(data, "app.models.clearAll") {
            let targetIds = searchInput.getValue().isEmpty ? nil : filteredItems.map { $0.fullId }
            enabledIds = clearAll(enabledIds, allIds, targetIds: targetIds)
            isDirty = true
            callbacks.onChange(enabledIds)
            refresh()
            return
        }

        if selectorKeyMatches(data, "app.models.toggleProvider") {
            guard let item = filteredItems[safe: selectedIndex] else { return }
            guard let provider = item.model?.provider else { return }
            let providerIds = allIds.filter { modelsById[$0]?.provider == provider }
            let allEnabled = providerIds.allSatisfy { isEnabled(enabledIds, $0) }
            enabledIds = allEnabled
                ? clearAll(enabledIds, allIds, targetIds: providerIds)
                : enableAll(enabledIds, allIds, targetIds: providerIds)
            isDirty = true
            callbacks.onChange(enabledIds)
            refresh()
            return
        }

        if selectorKeyMatches(data, "app.models.save") {
            callbacks.onPersist(enabledIds)
            isDirty = false
            footerText.setText(getFooterText())
            return
        }

        if matchesKey(data, Key.ctrl("c")) {
            if !searchInput.getValue().isEmpty {
                searchInput.setValue("")
                refresh()
            } else {
                callbacks.onCancel()
            }
            return
        }

        if matchesKey(data, Key.escape) {
            callbacks.onCancel()
            return
        }

        searchInput.handleInput(data)
        refresh()
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
