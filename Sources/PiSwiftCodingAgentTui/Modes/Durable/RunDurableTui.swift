import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable

/// Connects input to the plain view and controller.
@MainActor
final class DurableTuiSession {
    let source: any DurableViewSource
    let controller: any DurableController
    private(set) var tui: DurableTui!
    private(set) var active = true
    private var subscription: DurableViewSubscription?
    private var inputOpen = true
    private let exit: () -> Void

    init(source: any DurableViewSource, controller: any DurableController,
         terminal: any Terminal = ProcessTerminal(), exit: @escaping () -> Void) {
        self.source = source
        self.controller = controller
        self.exit = exit
        tui = DurableTui(cwd: source.current().session.cwd, handlers: DurableTuiHandlers(
            submit: { [weak self] in self?.submit($0) },
            followUp: { [weak self] text in self?.perform { await $0.submit(text, whenBusy: .followUp) } },
            abort: { [weak self] in self?.perform { await $0.abort() } },
            exit: exit,
            selectModel: { [weak self] in self?.selectModel() },
            cycleThinking: { [weak self] in self?.perform { await $0.cycleThinking() } }), terminal: terminal)
    }

    func subscribe() {
        subscription = source.subscribe { [weak self, source] in
            // Read on the serial listener queue, then transfer UI work to the main actor.
            let view = source.current()
            Task { @MainActor [weak self] in self?.apply(view) }
        }
    }
    func apply(_ view: DurableView) {
        guard active, inputOpen else { return }
        if view.terminal != nil { inputOpen = false }
        tui.apply(view)
        if !inputOpen { exit() }
    }

    func terminalClosed() {
        guard active, inputOpen else { return }
        inputOpen = false
        tui.apply(source.current())
        exit()
    }

    private var acceptsInput: Bool {
        guard active, inputOpen else { return false }
        let view = source.current()
        if view.terminal != nil { apply(view); return false }
        return true
    }

    private func perform(_ action: @escaping @MainActor (any DurableController) async -> Void) {
        guard acceptsInput else { return }
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
    }
    func stop() {
        unsubscribe()
        tui.stop()
    }
    private func submit(_ text: String) {
        guard acceptsInput else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if taskCommand(trimmed) { return }
        if trimmed == "/model" { selectModel(); return }
        if trimmed == "/tasks" { perform { await $0.toggleTasks() }; return }
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
        guard let command = parts.first, command == "/retry" || command == "/abort" else { return false }
        let parked = source.current().parkedTasks
        let id: TaskID
        if parts.count == 1, parked.count == 1 {
            id = parked[0].id
        } else if parts.count == 2, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int64(parts[1]), let parsed = try? TaskID(number) {
            id = parsed
        } else {
            tui.showError("Use \(command) <id>. Omit the ID only when one task is parked.")
            return true
        }
        if command == "/retry" { perform { await $0.retryTask(id) } }
        else { perform { await $0.abortTask(id) } }
        return true
    }
    private func selectModel() {
        guard acceptsInput else { return }
        let snapshot = source.current()
        let current: ModelRef?
        do { current = try decodeAgentOf(snapshot.conversation).model }
        catch { tui.apply(snapshot); return }
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
        let snapshot = source.current()
        let selector = ListSelector(title: "Switch to:", items: snapshot.conversations.reversed().map {
            SelectItem(value: String($0.id.rawValue), label: $0.label,
                description: ($0.id == snapshot.conversation.conversation.id ? "(shown) " : "") + ($0.title ?? ""))
        }, onSelect: { [weak self] value in
            guard let self, acceptsInput, let number = Int64(value), let id = try? ConversationID(number) else { return }
            tui.restoreEditor()
            perform { await $0.switchConversation(id) }
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
    await runDurableTui(view: durable.view, controller: durable.controller,
        settings: durable.settings, terminal: terminal, closed: { await durable.closed })
    await durable.close()
    return await durable.closed
}

/// Runs the durable interface until the user exits or the caller cancels.
@MainActor
public func runDurableTui(view source: any DurableViewSource, controller: any DurableController,
                          settings: SettingsManager) async {
    await runDurableTui(view: source, controller: controller, settings: settings, terminal: ProcessTerminal())
}

@MainActor
func runDurableTui(view source: any DurableViewSource, controller: any DurableController,
                   settings: SettingsManager, terminal: any Terminal,
                   closed: (@Sendable () async -> SessionCloseResult)? = nil) async {
    applyInteractiveTerminalCapabilities(settings)
    initTheme()
    let (exited, exit) = AsyncStream<Void>.makeStream()
    let session = DurableTuiSession(source: source, controller: controller, terminal: terminal, exit: { exit.finish() })
    let themes = InteractiveThemeController(ui: session.tui.ui, getSettingsManager: { settings },
        showError: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
        onChanged: { session.tui.ui.requestRender() })
    session.subscribe()
    let observer = closed.map { closed in
        Task { @MainActor in
            _ = await closed()
            guard !Task.isCancelled else { return }
            session.terminalClosed()
        }
    }
    session.tui.start()
    themes.applyFromSettings()
    session.apply(source.current())
    var iterator = exited.makeAsyncIterator()
    _ = await iterator.next()
    await session.tui.ui.waitForRender()
    observer?.cancel()
    session.unsubscribe()
    themes.dispose()
    session.stop()
}
