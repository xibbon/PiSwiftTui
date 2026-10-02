import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public enum OAuthSelectorMode: String, Sendable {
    case login
    case logout
}

public enum AuthType: String, Sendable {
    case oauth
    case apiKey = "api_key"
}

public enum AuthSelectorMethod: Sendable {
    case oauth(OAuthProviderInfo)
    case apiKey(ApiKeyAuthMethod)

    public var name: String {
        switch self {
        case .oauth(let method): method.name
        case .apiKey(let method): method.name
        }
    }
}

public struct AuthSelectorStatus: Sendable, Equatable {
    public let type: AuthType
    public let source: String?

    public init(type: AuthType, source: String? = nil) {
        self.type = type
        self.source = source
    }
}

public struct AuthSelectorProvider: Sendable {
    public let id: String
    public let name: String
    public let authType: AuthType
    public let method: AuthSelectorMethod?
    public let status: AuthSelectorStatus?
    public let subscription: Bool?

    public init(id: String, name: String, authType: AuthType, method: AuthSelectorMethod? = nil,
                status: AuthSelectorStatus? = nil, subscription: Bool? = nil) {
        self.id = id
        self.name = name
        self.authType = authType
        self.method = method
        self.status = status
        self.subscription = subscription
    }
}

func interactiveOAuthDeviceIdProvider(_ settings: SettingsManager) -> @Sendable () -> String {
    { settings.getOrCreateDeviceId() }
}

public func formatAuthSelectorProviderType(_ authType: AuthType, subscription: Bool? = nil) -> String {
    authType == .apiKey ? "API key" : subscription == false ? "account" : "subscription"
}

/// Q2: Keep raw library status sources and use readable text in the TUI.
public func authSelectorStatusSource(_ status: ProviderAuthStatus) -> String? {
    if let label = status.label { return label }
    switch status.source {
    case "stored": return nil
    case "models_json_key": return "key in models.json"
    case "models_json_command": return "command in models.json"
    case "fallback": return "extension"
    default: return status.source
    }
}

public func formatAuthSelectorProviderStatus(_ provider: AuthSelectorProvider) -> String {
    guard let status = provider.status else { return theme.fg(.muted, " • not configured") }
    if status.type != provider.authType {
        return theme.fg(.muted, " • ") + theme.fg(.warning,
            "\(formatAuthSelectorProviderType(status.type, subscription: provider.subscription)) configured")
    }
    guard let source = status.source, source != "OAuth", source != "stored credential" else {
        return theme.fg(.success, " ✓ configured")
    }
    let isEnvironmentName = source.range(of: "^[A-Z][A-Z0-9_]*(, [A-Z][A-Z0-9_]*)*$", options: .regularExpression) != nil
    return theme.fg(.success, " ✓ \(isEnvironmentName ? "env: " : "")\(source)")
}

public func getLoginProviderOptions(_ providers: [LoginProviderInfo], authType: AuthType? = nil,
    authStatus: (String) -> ProviderAuthStatus = { _ in ProviderAuthStatus(configured: false) },
    isUsingOAuth: (String) -> Bool = { _ in false }) -> [AuthSelectorProvider] {
    var options: [AuthSelectorProvider] = []
    for provider in providers {
        let rawStatus = authStatus(provider.id)
        let status = rawStatus.configured
            ? AuthSelectorStatus(type: isUsingOAuth(provider.id) ? .oauth : .apiKey, source: authSelectorStatusSource(rawStatus))
            : nil
        let subscription = provider.oauth?.isSubscription == true
        if (authType == nil || authType == .oauth), let oauth = provider.oauth, oauth.available {
            options.append(AuthSelectorProvider(id: provider.id, name: provider.name, authType: .oauth,
                method: .oauth(oauth), status: status, subscription: subscription))
        }
        if (authType == nil || authType == .apiKey), let apiKey = provider.apiKey {
            options.append(AuthSelectorProvider(id: provider.id, name: provider.name, authType: .apiKey,
                method: .apiKey(apiKey), status: status, subscription: subscription))
        }
    }
    return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

public func getLoginProviderOptions(_ registry: ModelRegistry, authType: AuthType? = nil) -> [AuthSelectorProvider] {
    getLoginProviderOptions(registry.getLoginProviders(), authType: authType,
        authStatus: { registry.getProviderAuthStatus($0) }, isUsingOAuth: { registry.isUsingOAuth($0) })
}

public func getLoginProviderCompletionOptions(_ options: [AuthSelectorProvider]) -> [AutocompleteItem] {
    let groups = Dictionary(grouping: options, by: \.id)
    return groups.values.sorted { $0[0].name.localizedCaseInsensitiveCompare($1[0].name) == .orderedAscending }.map { group in
        let provider = group[0]
        let types = [AuthType.oauth, .apiKey].compactMap { type in
            group.first { $0.authType == type }.map { formatAuthSelectorProviderType(type, subscription: $0.subscription) }
        }.joined(separator: "/")
        return AutocompleteItem(value: provider.id, label: provider.id,
            description: provider.name == provider.id ? types : "\(provider.name) · \(types)")
    }
}

public func getLoginProviderCompletionOptions(_ registry: ModelRegistry) -> [AutocompleteItem] {
    getLoginProviderCompletionOptions(getLoginProviderOptions(registry))
}

public func getLoginProviderCompletions(_ registry: ModelRegistry, query: String) -> [AutocompleteItem]? {
    getLoginProviderCompletions(getLoginProviderOptions(registry), query: query)
}

public func getLoginProviderCompletions(_ options: [AuthSelectorProvider], query: String) -> [AutocompleteItem]? {
    let items = getLoginProviderCompletionOptions(options)
    let filtered = fuzzyFilter(items, query: query) { item in
        let group = options.filter { $0.id == item.value }
        let types = [AuthType.oauth, .apiKey].compactMap { type in
            group.first { $0.authType == type }.map { "\(type.rawValue) \(formatAuthSelectorProviderType(type, subscription: $0.subscription))" }
        }.joined(separator: " ")
        return "\(item.value) \(group.first?.name ?? item.value) \(types)"
    }
    return filtered.isEmpty ? nil : filtered
}

@MainActor
public final class OAuthSelectorComponent: Container, Focusable, SystemCursorAware {
    private let searchInput = Input()
    private let listContainer = Container()
    private let allProviders: [AuthSelectorProvider]
    private var filteredProviders: [AuthSelectorProvider] = []
    private var selectedIndex = 0
    private let mode: OAuthSelectorMode
    private let showAuthTypeLabels: Bool
    private let onSelectCallback: (String, AuthType) -> Void
    private let onCancelCallback: () -> Void

    public var focused: Bool {
        get { searchInput.focused }
        set { searchInput.focused = newValue }
    }
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(mode: OAuthSelectorMode, providers: [AuthSelectorProvider],
                onSelect: @escaping (String, AuthType) -> Void, onCancel: @escaping () -> Void,
                initialSearchInput: String? = nil) {
        self.mode = mode
        self.allProviders = providers
        self.showAuthTypeLabels = Set(providers.map(\.authType)).count > 1
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        super.init()
        addChild(DynamicBorder())
        addChild(Spacer(1))
        let title = mode == .login ? "Select provider to configure:" : "Select provider to logout:"
        addChild(TruncatedText(theme.fg(.accent, theme.bold(title)), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        searchInput.setValue(initialSearchInput ?? "")
        searchInput.onSubmit = { [weak self] _ in self?.selectCurrentProvider() }
        addChild(searchInput)
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(DynamicBorder())
        filterProviders(initialSearchInput ?? "")
    }

    public func getSearchInput() -> Input { searchInput }

    private func filterProviders(_ query: String) {
        filteredProviders = query.isEmpty ? allProviders : fuzzyFilter(allProviders, query) {
            "\($0.name) \($0.id) \($0.authType.rawValue) \($0.method?.name ?? "")"
        }
        selectedIndex = max(0, min(selectedIndex, max(0, filteredProviders.count - 1)))
        updateList()
    }

    private func updateList() {
        listContainer.clear()
        let maxVisible = 8
        let start = max(0, min(selectedIndex - maxVisible / 2, filteredProviders.count - maxVisible))
        let end = min(start + maxVisible, filteredProviders.count)
        for index in start..<end {
            let provider = filteredProviders[index]
            let selected = index == selectedIndex
            let typeLabel = showAuthTypeLabels
                ? theme.fg(.muted, " [\(formatAuthSelectorProviderType(provider.authType, subscription: provider.subscription))]") : ""
            let prefix = selected ? theme.fg(.accent, "→ ") : "  "
            let name = theme.fg(selected ? .accent : .text, provider.name)
            listContainer.addChild(TruncatedText(prefix + name + typeLabel + formatAuthSelectorProviderStatus(provider), paddingX: 1, paddingY: 0))
        }
        if start > 0 || end < filteredProviders.count {
            listContainer.addChild(TruncatedText(theme.fg(.muted, "  (\(selectedIndex + 1)/\(filteredProviders.count))"), paddingX: 1, paddingY: 0))
        }
        if filteredProviders.isEmpty {
            let message = allProviders.isEmpty
                ? (mode == .login ? "No providers available" : "No providers logged in. Use /login first.")
                : "No matching providers"
            listContainer.addChild(TruncatedText(theme.fg(.muted, "  \(message)"), paddingX: 1, paddingY: 0))
        }
    }

    private func selectCurrentProvider() {
        guard filteredProviders.indices.contains(selectedIndex) else { return }
        let provider = filteredProviders[selectedIndex]
        onSelectCallback(provider.id, provider.authType)
    }

    public override func handleInput(_ keyData: String) {
        let kb = getKeybindings()
        if kb.matches(keyData, TUIKeybinding.selectUp) {
            guard !filteredProviders.isEmpty else { return }
            selectedIndex = max(0, selectedIndex - 1)
            updateList()
        } else if kb.matches(keyData, TUIKeybinding.selectDown) {
            guard !filteredProviders.isEmpty else { return }
            selectedIndex = min(filteredProviders.count - 1, selectedIndex + 1)
            updateList()
        } else if kb.matches(keyData, TUIKeybinding.selectConfirm) {
            selectCurrentProvider()
        } else if kb.matches(keyData, TUIKeybinding.selectCancel) {
            onCancelCallback()
        } else {
            searchInput.handleInput(keyData)
            filterProviders(searchInput.getValue())
        }
    }
}
