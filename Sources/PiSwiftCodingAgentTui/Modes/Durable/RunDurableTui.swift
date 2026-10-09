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

    init(source: any DurableViewSource, controller: any DurableController,
         terminal: any Terminal = ProcessTerminal(), exit: @escaping () -> Void) {
        self.source = source
        self.controller = controller
        tui = DurableTui(cwd: source.current().session.cwd, handlers: DurableTuiHandlers(
            submit: { [weak self] in self?.submit($0) },
            followUp: { [controller] text in Task { await controller.submit(text, whenBusy: .followUp) } },
            abort: { [controller] in Task { await controller.abort() } },
            exit: exit,
            selectModel: { [weak self] in self?.selectModel() },
            cycleThinking: { [controller] in Task { await controller.cycleThinking() } }), terminal: terminal)
    }

    func subscribe() {
        subscription = source.subscribe { [weak self] in
            // Listeners run on the view source's serial queue.
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                tui.apply(source.current())
            }
        }
    }
    func unsubscribe() {
        active = false
        subscription?.cancel()
        subscription = nil
    }
    func stop() {
        unsubscribe()
        tui.stop()
    }
    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == "/model" { selectModel(); return }
        if trimmed == "/tasks" { Task { await controller.toggleTasks() }; return }
        if trimmed == "/agents" { selectConversation(); return }
        if trimmed == "/compact" || trimmed.hasPrefix("/compact ") {
            let instructions = String(trimmed.dropFirst("/compact".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await controller.compact(instructions: instructions.isEmpty ? nil : instructions) }
            return
        }
        Task { await controller.submit(trimmed, whenBusy: .steer) }
    }
    private func selectModel() {
        let snapshot = source.current()
        let current = agentOf(snapshot.conversation).model
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
            guard let self, let separator = value.firstIndex(of: "/") else { return }
            tui.restoreEditor()
            let model = ModelRef(provider: String(value[..<separator]), modelId: String(value[value.index(after: separator)...]))
            Task { await self.controller.setModel(model) }
        }, onCancel: { [weak self] in self?.tui.restoreEditor() })
        tui.mount(selector)
    }
    private func selectConversation() {
        let snapshot = source.current()
        let selector = ListSelector(title: "Switch to:", items: snapshot.conversations.reversed().map {
            SelectItem(value: String($0.id.rawValue), label: $0.label,
                description: ($0.id == snapshot.conversation.conversation.id ? "(shown) " : "") + ($0.title ?? ""))
        }, onSelect: { [weak self] value in
            guard let self, let number = Int64(value), let id = try? ConversationID(number) else { return }
            tui.restoreEditor()
            Task { await self.controller.switchConversation(id) }
        }, onCancel: { [weak self] in self?.tui.restoreEditor() })
        tui.mount(selector)
    }
}

/// Runs the durable interface until the user exits or the caller cancels.
@MainActor
public func runDurableTui(view source: any DurableViewSource, controller: any DurableController,
                          settings: SettingsManager) async {
    await runDurableTui(view: source, controller: controller, settings: settings, terminal: ProcessTerminal())
}

@MainActor
func runDurableTui(view source: any DurableViewSource, controller: any DurableController,
                   settings: SettingsManager, terminal: any Terminal) async {
    applyInteractiveTerminalCapabilities(settings)
    initTheme()
    let (exited, exit) = AsyncStream<Void>.makeStream()
    let session = DurableTuiSession(source: source, controller: controller, terminal: terminal, exit: { exit.finish() })
    let themes = InteractiveThemeController(ui: session.tui.ui, getSettingsManager: { settings },
        showError: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) },
        onChanged: { session.tui.ui.requestRender() })
    session.subscribe()
    session.tui.start()
    themes.applyFromSettings()
    session.tui.apply(source.current())
    var iterator = exited.makeAsyncIterator()
    _ = await iterator.next()
    session.unsubscribe()
    themes.dispose()
    session.stop()
}
