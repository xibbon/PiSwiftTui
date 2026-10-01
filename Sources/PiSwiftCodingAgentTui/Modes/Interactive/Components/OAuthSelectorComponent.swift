import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public enum OAuthSelectorMode: String, Sendable {
    case login
    case logout
}

func interactiveOAuthDeviceIdProvider(_ settings: SettingsManager) -> @Sendable () -> String {
    { settings.getOrCreateDeviceId() }
}

/// Completion options for `/login <provider>`, ordered exactly as the provider selector.
/// The id is inserted so a completed command is stable even when display names change.
public func getLoginProviderCompletionOptions(_ providers: [OAuthProviderInfo] = getOAuthProviders()) -> [AutocompleteItem] {
    providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map {
        AutocompleteItem(value: $0.id.rawValue, label: $0.name, description: "subscription")
    }
}

public final class OAuthSelectorComponent: Container {
    private let listContainer: Container
    private var allProviders: [OAuthProviderInfo] = []
    private var selectedIndex = 0
    private let mode: OAuthSelectorMode
    private let authStorage: AuthStorage
    private let onSelectCallback: (String) -> Void
    private let onCancelCallback: () -> Void

    public init(
        mode: OAuthSelectorMode,
        authStorage: AuthStorage,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.authStorage = authStorage
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.listContainer = Container()
        super.init()

        loadProviders()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        let title = mode == .login ? "Select provider to login:" : "Select provider to logout:"
        addChild(TruncatedText(theme.bold(title)))
        addChild(Spacer(1))

        addChild(listContainer)
        addChild(Spacer(1))
        addChild(DynamicBorder())

        updateList()
    }

    private func loadProviders() {
        allProviders = getOAuthProviders()
    }

    private func updateList() {
        listContainer.clear()

        for index in allProviders.indices {
            let provider = allProviders[index]
            let isSelected = index == selectedIndex
            let isAvailable = provider.available
            let credentials = authStorage.get(provider.id.rawValue)
            let isLoggedIn: Bool
            if case .oauth = credentials {
                isLoggedIn = true
            } else {
                isLoggedIn = false
            }
            let status = isLoggedIn ? theme.fg(.success, " (logged in)") : ""
            let label = mode == .login ? provider.loginLabel ?? provider.name : provider.name

            let line: String
            if isSelected {
                let prefix = theme.fg(.accent, "→ ")
                let name = isAvailable ? theme.fg(.accent, label) : theme.fg(.dim, label)
                line = prefix + name + status
            } else {
                let name = isAvailable ? "  \(label)" : theme.fg(.dim, "  \(label)")
                line = name + status
            }

            listContainer.addChild(TruncatedText(line, paddingX: 0, paddingY: 0))
        }

        if allProviders.isEmpty {
            let message = mode == .login
                ? "No OAuth providers available"
                : "No OAuth providers logged in. Use /login first."
            listContainer.addChild(TruncatedText(theme.fg(.muted, "  \(message)"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ keyData: String) {
        if isArrowUp(keyData) {
            selectedIndex = max(0, selectedIndex - 1)
            updateList()
            return
        }
        if isArrowDown(keyData) {
            selectedIndex = min(allProviders.count - 1, selectedIndex + 1)
            updateList()
            return
        }
        if isEnter(keyData) {
            let selected = selectedIndex >= 0 && selectedIndex < allProviders.count
                ? allProviders[selectedIndex]
                : nil
            if selected?.available == true, let selected {
                onSelectCallback(selected.id.rawValue)
            }
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
            return
        }
    }
}
