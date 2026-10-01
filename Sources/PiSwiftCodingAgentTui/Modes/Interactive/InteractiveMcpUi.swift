import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Connect the built-in MCP extension to the interactive custom-component host.
@MainActor
public final class InteractiveMcpUi: McpUi {
    private var custom: ((@escaping HookCustomFactory) async -> HookCustomResult?)?
    private var requestRender: @MainActor @Sendable () -> Void = {}
    private var notify: @MainActor @Sendable (String) -> Void = { _ in }
    private var view: McpManagerView?
    private var managerTask: Task<Void, Never>?
    private var closeManager: HookCustomClose?
    private var managerClosed = false

    public init() {}

    func attach(custom: @escaping (@escaping HookCustomFactory) async -> HookCustomResult?,
                requestRender: @escaping @MainActor @Sendable () -> Void,
                notify: @escaping @MainActor @Sendable (String) -> Void) {
        self.custom = custom
        self.requestRender = requestRender
        self.notify = notify
    }

    /// Keep one custom view mounted until the library manager returns.
    func runManager(_ operation: @escaping @Sendable () async throws -> Void) async {
        guard let custom else { return }
        let view = McpManagerView(theme: theme, requestRender: requestRender)
        self.view = view
        managerClosed = false
        await withTaskCancellationHandler {
            _ = await custom { [weak self, view] _, _, _, done in
                await self?.start(operation, done: done)
                return view
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelManager() }
        }
        await managerTask?.value
        view.dispose()
        self.view = nil
        closeManager = nil
        managerTask = nil
    }

    private func start(_ operation: @escaping @Sendable () async throws -> Void, done: @escaping HookCustomClose) {
        closeManager = done
        guard !managerClosed else { done(nil); return }
        managerTask = Task { @MainActor [weak self] in
            do { try await operation() }
            catch { if !Task.isCancelled { self?.notify(error.localizedDescription) } }
            self?.finishManager()
        }
    }

    func cancelManager() {
        managerTask?.cancel()
        finishManager()
    }

    private func finishManager() {
        guard !managerClosed else { return }
        managerClosed = true
        view?.dispose()
        closeManager?(nil)
    }

    public func menu(_ menu: McpMenu) async -> String? { await view?.menu(menu) }

    public func menu(build: @escaping @Sendable () async -> McpMenu,
                     changes: AsyncStream<Void>?) async -> String? {
        await view?.menu(build: build, changes: changes)
    }

    public func status(title: String, message: String) { view?.status(title: title, message: message) }

    public func redirectURL(title: String, authorizationURL: URL) async -> URL? {
        await view?.redirectURL(title: title, authorizationURL: authorizationURL)
    }
}
