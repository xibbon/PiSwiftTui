import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

/// `PI_OFFLINE=1` suppresses the startup catalog refresh, matching upstream's `process.env` check.
/// Duplicated from `CLIOptions.isOfflineEnvironmentEnabled` because the CLI module depends on this
/// one, not the other way around.
func isOfflineEnvironmentEnabled(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    env["PI_OFFLINE"] == "1"
}

/// A `/model` argument, either `id` or `provider/id`, normalized for case-insensitive matching.
/// Matching is kept separate from the refresh flow so `/model <name>` can be resolved against the
/// cached catalogs before deciding whether a network refresh is needed at all (#7443).
struct ModelReference {
    let provider: String?
    let id: String

    init?(_ searchTerm: String) {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        if let slashIndex = term.firstIndex(of: "/") {
            provider = String(term[..<slashIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            id = String(term[term.index(after: slashIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } else {
            provider = nil
            id = term.lowercased()
        }

        guard !id.isEmpty else { return nil }
    }

    /// The single model this reference names, or nil when it matches none or is ambiguous.
    func exactMatch(in models: [Model]) -> Model? {
        let matches = models.filter { model in
            let idMatch = model.id.lowercased() == id
            let providerMatch = provider == nil || model.provider.lowercased() == provider
            return idMatch && providerMatch
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Upstream bounds every interactive catalog refresh with a 15s `AbortController`
/// (`interactive-mode.ts`, `model-selector.ts`). A refresh that stalls must never hold the UI.
let catalogRefreshTimeoutMs = 15_000

/// A selector that owns background work which must stop when it leaves the screen.
@MainActor
protocol SelectorClosable: AnyObject {
    func closeSelector()
}

/// Lets `showSelector` tear down a component that is not built until after `done` is created.
@MainActor
final class SelectorCloseBox {
    weak var component: (any SelectorClosable)?
    private var closed = false

    func closeOnce() {
        guard !closed else { return }
        closed = true
        component?.closeSelector()
        component = nil
    }
}

/// Outcome of a bounded refresh: the coordinator's result plus whether *our* timeout fired.
/// `result.aborted` alone cannot distinguish a timeout from a caller-initiated cancel.
struct BoundedCatalogRefreshOutcome {
    var result: ModelsRefreshResult
    var timedOut: Bool
}

/// Runs `registry.refresh` with the network enabled, bounded by `timeoutMs`.
///
/// `signal` is owned by the caller so it can cancel the refresh independently (e.g. when a
/// selector closes). The timeout cancels the same token, matching upstream's single-controller
/// design. Callers must not `await` this on a path that blocks startup or user input — the whole
/// point of the follow-up is that these refreshes run in the background over cached content.
@MainActor
func runBoundedCatalogRefresh(
    registry: ModelRegistry,
    providers: [String]? = nil,
    signal: CancellationToken,
    timeoutMs: Int = catalogRefreshTimeoutMs
) async -> BoundedCatalogRefreshOutcome {
    let state = CatalogRefreshTimeoutState()
    let timeoutTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        guard !Task.isCancelled else { return }
        state.timedOut = true
        signal.cancel()
    }
    defer { timeoutTask.cancel() }

    let result = await interactiveCatalogRefreshCoordinator.refresh(
        registry: registry, providers: providers, signal: signal
    )
    return BoundedCatalogRefreshOutcome(result: result, timedOut: state.timedOut)
}

@MainActor
private final class CatalogRefreshTimeoutState {
    var timedOut = false
}

/// Provider ids of every catalog that failed, sorted for a deterministic message.
///
/// Upstream reads a `Map` in insertion order; `ModelsRefreshResult.errors` is an unordered
/// dictionary, and the coordinator already runs sources sorted by id, so sorting reproduces
/// upstream's order while staying testable.
func failedCatalogNames(_ result: ModelsRefreshResult) -> [String] {
    result.errors.keys.sorted()
}

/// Messages shown when a bounded refresh finishes. Each mirrors an upstream call site verbatim;
/// the wording differs per site ("showing" vs "searching" cached models), so they stay separate.
enum CatalogRefreshStatus {
    /// `model-selector.ts` — the `/model` picker. Counts catalogs when more than one failed.
    static func selectorMessage(_ outcome: BoundedCatalogRefreshOutcome) -> String? {
        if outcome.result.aborted && outcome.timedOut {
            return "Model refresh timed out; showing cached models."
        }
        let failed = failedCatalogNames(outcome.result)
        if failed.count == 1 {
            return "Could not refresh \(failed[0]); showing cached models."
        }
        if failed.count > 1 {
            return "Could not refresh \(failed.count) model catalogs (\(failed.joined(separator: ", "))); showing cached models."
        }
        return nil
    }

    /// `findExactModelMatch` — `/model <name>`, which searches rather than displays.
    static func exactMatchWarning(_ outcome: BoundedCatalogRefreshOutcome) -> String? {
        if outcome.result.aborted && outcome.timedOut {
            return "Model refresh timed out; searching cached models."
        }
        let failed = failedCatalogNames(outcome.result)
        guard !failed.isEmpty else { return nil }
        return "Could not refresh \(failed.joined(separator: ", ")); searching cached models."
    }

    /// `/scoped-models` — always names every failed catalog, and reports success.
    static func scopedModelsMessage(_ outcome: BoundedCatalogRefreshOutcome) -> (text: String, isError: Bool) {
        if outcome.result.aborted && outcome.timedOut {
            return ("Model refresh timed out; showing cached models.", true)
        }
        let failed = failedCatalogNames(outcome.result)
        if !failed.isEmpty {
            return ("Could not refresh \(failed.joined(separator: ", ")); showing cached models.", true)
        }
        return ("Model catalogs refreshed.", false)
    }

    /// Post-login / post-logout, refreshing a single provider's catalog.
    static func authMessage(_ outcome: BoundedCatalogRefreshOutcome, actionLabel: String) -> String? {
        if outcome.result.aborted {
            return "\(actionLabel), but its model catalog refresh timed out; using cached models."
        }
        guard !outcome.result.errors.isEmpty else { return nil }
        return "\(actionLabel), but its model catalog could not be refreshed; using cached models."
    }
}

/// One operation serves concurrent callers. Each caller retains its own cancellation token.
@MainActor
final class InteractiveCatalogRefreshCoordinator {
    @MainActor
    private final class Active {
        let signal = CancellationToken()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<ModelsRefreshResult, Never>] = [:]
    }
    private struct Key: Hashable {
        let runtime: ObjectIdentifier
        let providers: [String]?
    }
    private var active: [Key: Active] = [:]

    func refresh(registry: ModelRegistry, providers: [String]? = nil,
                 signal: CancellationToken) async -> ModelsRefreshResult {
        await refresh(runtime: registry, providers: providers, signal: signal) { signal in
            await registry.refresh(ModelsRefreshOptions(providers: providers, signal: signal))
        }
    }

    func refresh(runtime: AnyObject, providers: [String]? = nil, signal: CancellationToken,
                 operation: @escaping @MainActor (CancellationToken) async -> ModelsRefreshResult
    ) async -> ModelsRefreshResult {
        guard !signal.isCancelled, !Task.isCancelled else { return ModelsRefreshResult(aborted: true) }
        let key = Key(runtime: ObjectIdentifier(runtime), providers: providers?.sorted())
        let entry: Active
        if let existing = active[key] {
            entry = existing
        } else {
            entry = Active()
            active[key] = entry
            entry.task = Task { @MainActor [weak self] in
                let result = await operation(entry.signal)
                guard let self, self.active[key] === entry else { return }
                self.active.removeValue(forKey: key)
                let waiters = entry.waiters.values
                entry.waiters.removeAll()
                for waiter in waiters { waiter.resume(returning: result) }
            }
        }
        let id = UUID()
        // The handler runs on the cancelling thread. Hop to the main actor before touching state.
        let removeObserver = signal.onCancel { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelWaiter(key: key, entry: entry, id: id)
            }
        }
        defer { removeObserver() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entry.waiters[id] = continuation
                if signal.isCancelled || Task.isCancelled {
                    cancelWaiter(key: key, entry: entry, id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(key: key, entry: entry, id: id)
            }
        }
    }

    private func cancelWaiter(key: Key, entry: Active, id: UUID) {
        guard let waiter = entry.waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: ModelsRefreshResult(aborted: true))
        if entry.waiters.isEmpty, active[key] === entry {
            active.removeValue(forKey: key)
            entry.signal.cancel()
            entry.task?.cancel()
        }
    }
}

@MainActor
private let interactiveCatalogRefreshCoordinator = InteractiveCatalogRefreshCoordinator()
