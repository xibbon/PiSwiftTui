import Foundation
import Darwin
import MiniTui
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable

/// Connects input to one coalesced host view and controller.
@MainActor
final class DurableTuiSession {
    var source: any DurableHostViewSource
    var controller: any DurableHostController
    private(set) var tui: DurableTui!
    private(set) var active = true
    private var subscription: DurableViewSubscription?
    private var inputOpen = true
    private let exit: () -> Void
    var refresh: (() async throws -> OpenDurableResult)?
    var reopen: (() async throws -> OpenDurableResult)?
    var refreshedDurable: OpenDurableResult?
    var closedObserver: Task<Void, Never>?
    private var latest: DurableHostView

    init(source: any DurableHostViewSource, controller: any DurableHostController,
         terminal: any Terminal = ProcessTerminal(), exit: @escaping () -> Void) {
        self.source = source
        self.controller = controller
        self.exit = exit
        latest = source.hostCurrent()
        tui = DurableTui(cwd: latest.session.cwd, handlers: DurableTuiHandlers(
            submit: { [weak self] in self?.submit($0) },
            followUp: { [weak self] text in self?.perform { await $0.submit(text, whenBusy: .followUp) } },
            abort: { [weak self] in self?.perform { await $0.abort() } },
            exit: exit,
            selectModel: { [weak self] in self?.selectModel() },
            cycleThinking: { [weak self] in self?.perform { await $0.cycleThinking() } },
            loadEarlier: { [weak self] in self?.loadEarlier() },
            fillGap: { [weak self] gap in self?.fillGap(gap) },
            refresh: { [weak self] in self?.refreshSnapshot() }), terminal: terminal)
    }

    func subscribe() {
        subscription = source.subscribe { [weak self, source] in
            // Read on the serial listener queue, then transfer UI work to the main actor.
            let view = source.hostCurrent()
            Task { @MainActor [weak self] in self?.apply(view) }
        }
    }
    func apply(_ view: DurableHostView) {
        guard active, inputOpen else { return }
        latest = view
        if view.terminal != nil { inputOpen = false }
        tui.apply(view)
        if view.terminal == .closed { exit() }
    }

    func terminalClosed() {
        guard active else { return }
        inputOpen = false
        let view = source.hostCurrent()
        tui.apply(view)
        if view.terminal == .closed { exit() }
    }

    private var acceptsInput: Bool {
        guard active, inputOpen else { return false }
        let view = source.hostCurrent()
        if view.terminal != nil { apply(view); return false }
        latest = view
        return true
    }

    private func perform(writes: Bool = true, _ action: @escaping @MainActor (any DurableHostController) async -> Void) {
        guard acceptsInput else { return }
        if writes && latest.openMode == .readOnly {
            tui.showError("Read-only session: writing commands are disabled. Use /refresh to see new entries.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self, acceptsInput else { return }
            await action(controller)
        }
    }

    func unsubscribe() {
        active = false
        inputOpen = false
        subscription?.cancel()
        subscription = nil
        closedObserver?.cancel()
        closedObserver = nil
    }
    func stop() {
        unsubscribe()
        tui.stop()
    }
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == "/reopen" {
            reopenSession()
            return
        }
        guard acceptsInput else { return }
        if trimmed == "/help" {
            tui.showError("Commands: /continue · /earlier (Ctrl-E) · /gap · /refresh (Ctrl-R) · /model · /agents · /tasks · /compact · /abort <id> · Ctrl-D to quit")
            return
        }
        if trimmed == "/earlier" { loadEarlier(); return }
        if trimmed == "/gap" {
            guard let gap = latest.rows.compactMap({ row -> TranscriptGap? in
                if case .gap(let gap) = row.item { return gap }
                return nil
            }).first else { tui.showError("No transcript gap is available."); return }
            fillGap(gap)
            return
        }
        if trimmed == "/refresh" { refreshSnapshot(); return }
        if trimmed == "/continue" { perform { await $0.continueRun() }; return }
        if taskCommand(trimmed) { return }
        if trimmed == "/model" { selectModel(); return }
        if trimmed == "/tasks" { perform(writes: false) { await $0.toggleTasks() }; return }
        if trimmed == "/agents" { selectConversation(); return }
        if trimmed == "/compact" || trimmed.hasPrefix("/compact ") {
            let instructions = String(trimmed.dropFirst("/compact".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            perform { await $0.compact(instructions: instructions.isEmpty ? nil : instructions) }
            return
        }
        perform { await $0.submit(trimmed, whenBusy: .steer) }
    }
    private func taskCommand(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard let command = parts.first, command == "/abort" else { return false }
        let id: TaskID
        if parts.count == 2, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int64(parts[1]), let parsed = try? TaskID(number) {
            id = parsed
        } else {
            tui.showError("Use /abort <id>.")
            return true
        }
        perform { await $0.abortTask(id) }
        return true
    }
    private func loadEarlier() {
        guard latest.rows.contains(where: {
            if case .earlier = $0.item { return true }
            return false
        }) else { tui.showError("No earlier entries are available."); return }
        perform(writes: false) { await $0.loadEarlier() }
    }
    private func fillGap(_ gap: TranscriptGap) {
        perform(writes: false) { await $0.fillGap(gap) }
    }
    private func refreshSnapshot() {
        guard acceptsInput else { return }
        guard latest.openMode == .readOnly else {
            tui.showError("Refresh is available in read-only mode.")
            return
        }
        guard let refresh else { tui.showError("Refresh is unavailable."); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            closedObserver?.cancel()
            closedObserver = nil
            subscription?.cancel()
            subscription = nil
            do {
                let opened = try await refresh()
                refreshedDurable = opened
                self.refresh = { try await opened.refresh() }
                source = opened.hostView
                controller = opened.hostController
                subscribe()
                apply(source.hostCurrent())
                watchClosed { await opened.closed }
            } catch {
                tui.showError("Refresh failed: \(error)")
                exit()
            }
        }
    }
    private func reopenSession() {
        guard active, !inputOpen, case .failed = latest.terminal, let reopen else {
            tui.showError("Reopen is available after a session failure.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            closedObserver?.cancel()
            closedObserver = nil
            subscription?.cancel()
            subscription = nil
            do {
                let opened = try await reopen()
                refreshedDurable = opened
                source = opened.hostView
                controller = opened.hostController
                refresh = { try await opened.refresh() }
                inputOpen = true
                tui.resetForReopen()
                subscribe()
                apply(source.hostCurrent())
                watchClosed { await opened.closed }
            } catch {
                tui.showError("Reopen failed: \(error)")
            }
        }
    }
    func watchClosed(_ closed: @escaping @Sendable () async -> SessionCloseResult) {
        closedObserver = Task { @MainActor [weak self] in
            _ = await closed()
            guard !Task.isCancelled else { return }
            self?.terminalClosed()
        }
    }
    private func selectModel() {
        guard acceptsInput else { return }
        if latest.openMode == .readOnly {
            tui.showError("Read-only session: writing commands are disabled. Use /refresh to see new entries.")
            return
        }
        let snapshot = latest
        let current = snapshot.agent.model
        func isCurrent(_ model: ModelSummary) -> Bool {
            model.provider == current?.provider && model.modelId == current?.modelId
        }
        let models = snapshot.models.enumerated().sorted {
            if isCurrent($0.element) != isCurrent($1.element) { return isCurrent($0.element) }
            return $0.offset < $1.offset
        }.map(\.element)
        let selector = ListSelector(title: "Select model:", items: models.map {
            SelectItem(value: "\($0.provider)/\($0.modelId)", label: $0.modelId, description: $0.provider)
        }, onSelect: { [weak self] value in
            guard let self, acceptsInput, let separator = value.firstIndex(of: "/") else { return }
            tui.restoreEditor()
            let model = ModelRef(provider: String(value[..<separator]), modelId: String(value[value.index(after: separator)...]))
            perform { await $0.setModel(model) }
        }, onCancel: { [weak self] in
            guard let self, acceptsInput else { return }
            tui.restoreEditor()
        })
        tui.mount(selector)
    }
    private func selectConversation() {
        guard acceptsInput else { return }
        let snapshot = latest
        let selector = ListSelector(title: "Switch to:", items: snapshot.conversations.reversed().map {
            SelectItem(value: String($0.id.rawValue), label: $0.label,
                description: ($0.id == snapshot.transcript.conversation.id ? "(shown) " : "") + ($0.title ?? ""))
        }, onSelect: { [weak self] value in
            guard let self, acceptsInput, let number = Int64(value), let id = try? ConversationID(number) else { return }
            tui.restoreEditor()
            perform(writes: false) { await $0.switchConversation(id) }
        }, onCancel: { [weak self] in
            guard let self, acceptsInput else { return }
            tui.restoreEditor()
        })
        tui.mount(selector)
    }
}

/// Runs the durable interface and waits for storage, environment, and lock cleanup.
@MainActor
public func runDurableTui(_ durable: OpenDurableResult) async -> SessionCloseResult {
    await runDurableTui(durable, terminal: ProcessTerminal())
}

@MainActor
func runDurableTui(_ durable: OpenDurableResult, terminal: any Terminal) async -> SessionCloseResult {
    let final = await runDurableTuiCore(view: durable.hostView, controller: durable.hostController,
        settings: durable.settings, terminal: terminal, closed: { await durable.closed },
        refresh: { try await durable.refresh() },
        reopen: {
            let snapshot = durable.hostView.hostCurrent()
            return try await openDurable(.init(cwd: snapshot.session.cwd, continueSession: true,
                                                mode: snapshot.openMode, transcriptMode: .paged,
                                                sessionID: snapshot.session.id))
        })
    let current = final ?? durable
    await current.close()
    return await current.closed
}

/// Runs the durable interface until the user exits or the caller cancels.
@MainActor
public func runDurableTui(view source: any DurableHostViewSource, controller: any DurableHostController,
                          settings: SettingsManager) async {
    await runDurableTui(view: source, controller: controller, settings: settings, terminal: ProcessTerminal())
}

@MainActor
func runDurableTui(view source: any DurableHostViewSource, controller: any DurableHostController,
                   settings: SettingsManager, terminal: any Terminal,
                   closed: (@Sendable () async -> SessionCloseResult)? = nil) async {
    _ = await runDurableTuiCore(view: source, controller: controller, settings: settings,
                               terminal: terminal, closed: closed)
}

@MainActor
private func runDurableTuiCore(view source: any DurableHostViewSource, controller: any DurableHostController,
                   settings: SettingsManager, terminal: any Terminal,
                   closed: (@Sendable () async -> SessionCloseResult)? = nil,
                   refresh: (() async throws -> OpenDurableResult)? = nil,
                   reopen: (() async throws -> OpenDurableResult)? = nil) async -> OpenDurableResult? {
    applyInteractiveTerminalCapabilities(settings)
    initTheme()
    let (exited, exit) = AsyncStream<Void>.makeStream()
    let session = DurableTuiSession(source: source, controller: controller, terminal: terminal, exit: { exit.finish() })
    if terminal is ProcessTerminal { _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1) }
    session.tui.ui.setIOErrorHandler { error in
        // A lost terminal cannot show the recovery UI. Match the interactive exit status.
        Darwin.exit(error.isTerminalLoss ? 129 : 1)
    }
    session.refresh = refresh
    session.reopen = reopen
    let themes = InteractiveThemeController(ui: session.tui.ui, getSettingsManager: { settings },
        showError: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
        onChanged: { session.tui.ui.requestRender() })
    session.subscribe()
    if let closed { session.watchClosed(closed) }
    session.tui.start()
    themes.applyFromSettings()
    session.apply(source.hostCurrent())
    var iterator = exited.makeAsyncIterator()
    _ = await iterator.next()
    await session.tui.ui.waitForRender()
    let final = session.refreshedDurable
    session.unsubscribe()
    session.tui.ui.setIOErrorHandler(nil)
    themes.dispose()
    session.stop()
    return final
}
