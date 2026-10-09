import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable

@MainActor
struct DurableTuiHandlers {
    var submit: (String) -> Void
    var followUp: (String) -> Void
    var abort: () -> Void
    var exit: () -> Void
    var selectModel: () -> Void
    var cycleThinking: () -> Void
}

@MainActor
final class DurableTui {
    private static let renderers = createAllToolRenderers()
    let ui: TUI
    let renderer: AltScreenRenderer
    let layoutRoot = VStack()
    let chat = Container()
    let tasks = Container()
    let queue = Container()
    let notices = Container()
    let footer = Container()
    private let footerStats = Text("", paddingX: 1, paddingY: 0)
    private let footerHints = Text("", paddingX: 1, paddingY: 0)
    let editorContainer = Container()
    let editor: CustomEditor
    private let cwd: String
    // Keep both the newest card per call ID and all displayed cards.
    private(set) var tools: [String: ToolExecutionComponent] = [:]
    private(set) var cards: [ToolExecutionComponent] = []
    private var cardCalls: [(String, String)] = []
    private var streamingCalls: Set<String> = []
    private(set) var summaries: [CompactionComponent] = []
    private(set) var expanded = false
    private var renderedEntryIds: [EntryID] = []
    private var streaming: AssistantMessageComponent?
    private var indicator: WorkingStatusIndicator?
    private var statusText = ""
    private var rebuilt = false
    let transcript: ScrollView

    init(cwd: String, handlers: DurableTuiHandlers, terminal: any Terminal = ProcessTerminal()) {
        self.cwd = cwd
        ui = TUI(terminal: terminal, showHardwareCursor: false, logDirectory: getAgentDir())
        renderer = ui.enableAltScreen()
        let keybindings = KeybindingsManager.create()
        editor = CustomEditor(ui: ui, theme: getEditorTheme(), keybindings: keybindings,
                              options: EditorOptions(paddingX: 1), embedWorkingStatus: true)
        let content = Container()
        content.addChild(chat)
        content.addChild(Spacer(1))
        transcript = ScrollView(content, options: ScrollViewOptions(follow: .end, primary: true, overscroll: .chain))
        editor.onSubmit = handlers.submit
        editor.onEscape = handlers.abort
        editor.onCtrlD = handlers.exit
        editor.onAction(.clear, handler: handlers.exit)
        editor.onAction(.selectModel, handler: handlers.selectModel)
        editor.onAction(.cycleThinkingLevel, handler: handlers.cycleThinking)
        editor.onAction(.expandTools) { [weak self] in
            guard let self else { return }
            expanded.toggle()
            for card in cards { card.setExpanded(expanded) }
            for summary in summaries { summary.setExpanded(expanded) }
            ui.requestRender()
        }
        editor.onAction(.followUp) { [weak self] in
            guard let self else { return }
            let text = editor.getText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            editor.setText("")
            handlers.followUp(text)
        }
        editorContainer.addChild(editor)
        footer.addChild(footerStats)
        footer.addChild(footerHints)
        let dock = VStack(children: [tasks, queue, notices, editorContainer, footer].map {
            .entry(StackEntry($0, options: StackEntryOptions(shrink: 1, minSize: $0 === editorContainer ? 3 : 0)))
        })
        for component in [chat, tasks, queue, notices, editorContainer, footer] { ui.addChild(component) }
        layoutRoot.addChild(transcript, options: StackEntryOptions(basis: .points(0), grow: 1, shrink: 1, minSize: 1))
        layoutRoot.addChild(dock, options: StackEntryOptions(basis: .auto, grow: 0, shrink: 1, minSize: 1))
        renderer.setLayoutRoot(layoutRoot)
        ui.switchRenderer(to: .altScreen)
        ui.setFocus(editor)
    }

    func start() { ui.start() }
    func stop() {
        discardTools()
        indicator?.dispose()
        indicator = nil
        editor.setWorkingStatusIndicator(nil)
        ui.stop()
    }
    private func discardTools() {
        for (card, call) in zip(cards, cardCalls) {
            card.updateResult(ToolResultMessage(toolCallId: call.1, toolName: call.0, content: [], isError: false))
        }
        cards.removeAll()
        cardCalls.removeAll()
        tools.removeAll()
        streamingCalls.removeAll()
    }
    func mount(_ component: any Component) {
        editorContainer.clear()
        editorContainer.addChild(component)
        ui.setFocus(component)
        ui.requestRender()
    }
    func restoreEditor() { mount(editor) }

    func apply(_ view: DurableView) {
        let live = view.conversation.docs["pi.live"].flatMap { try? JSONValue.object($0).decode(LiveState.self) } ?? LiveState()
        syncTranscript(view.conversation.entries)
        let message = durableAssistant(live.generation?.message)
        if message == nil, streaming != nil { rebuild(view.conversation.entries) }
        if let message { syncStreaming(message) }
        for slot in live.tools ?? [] where slot.status != .pending {
            let component = tool(slot.name, callId: slot.callId)
            component.setArgsComplete()
            guard slot.status == .running else { continue }
            component.markExecutionStarted()
            let child = slot.details?.objectValue?["conversationId"]?.numberValue
            let output = slot.output ?? child.map { "Subagent \(Int($0)) is working. /agents switches to it." }
            if let output {
                component.updateResult(ToolResultMessage(toolCallId: slot.callId, toolName: slot.name,
                    content: [.text(TextContent(text: output))],
                    details: slot.details.flatMap { try? AnyCodable(foundationJSON(from: $0)) }, isError: false), isPartial: true)
            }
        }
        syncTasks(view.tasks)
        syncQueue(view.conversation.docs["pi.inbox"].flatMap { try? JSONValue.object($0).decode(InboxState.self) } ?? InboxState())
        notices.clear()
        for item in view.notices.suffix(4) {
            let color: ThemeColor = item.level == .error ? .error : item.level == .warning ? .warning : .muted
            notices.addChild(TruncatedText(theme.fg(color, item.message), paddingX: 1, paddingY: 0))
        }
        let level = agentOf(view.conversation).thinkingLevel?.rawValue ?? "off"
        editor.borderColor = { theme.getThinkingBorderColor(level)($0) }
        syncStatus(live)
        syncFooter(view)
        if rebuilt { transcript.scrollToEnd() }
        ui.requestRender(force: rebuilt)
        rebuilt = false
    }

    private func syncTasks(_ graph: TaskGraph?) {
        tasks.clear()
        guard let graph else { return }
        // JavaScript Object.values orders decimal ID keys numerically.
        let nodes = graph.tasks.values.sorted { $0.id < $1.id }
        var lines = [theme.fg(.accent, "Tasks (\(nodes.count) live, /tasks to hide)")]
        let owned = Set(nodes.flatMap(\.conversations))
        func visit(_ node: TaskGraphNode, depth: Int) {
            lines.append(String(repeating: "  ", count: depth + 1) + describeTask(node))
            for child in nodes where child.owner == node.id || (child.owner == nil && node.conversations.contains(child.conversationId)) {
                visit(child, depth: depth + 1)
            }
        }
        for node in nodes where node.owner == nil && !owned.contains(node.conversationId) { visit(node, depth: 0) }
        for line in lines { tasks.addChild(TruncatedText(theme.fg(.muted, line), paddingX: 1, paddingY: 0)) }
    }
    private func syncQueue(_ inbox: InboxState) {
        queue.clear()
        for item in inbox.items {
            let text = item.mode == .write ? "<\(item.entry?.kind ?? "undefined")>" : userText(item.content)
            queue.addChild(TruncatedText(theme.fg(.muted, "[\(item.mode.rawValue)] \(text)"), paddingX: 1, paddingY: 0))
        }
    }
    private func syncStatus(_ live: LiveState) {
        var text = ""
        if let retry = live.generation?.retry {
            text = "Retrying (attempt \((live.generation?.attempt ?? 0) + 1)): \(retry.error)"
        } else if live.generation?.deferred != nil { text = "Waiting for deferred response..." }
        else if let compaction = live.compactions?.first {
            text = compaction.retry != nil ? "Retrying \(compaction.reason.rawValue) compaction (attempt \(compaction.attempt + 1))..." : "Compacting (\(compaction.reason.rawValue))..."
        } else if let tool = live.tools?.first(where: { $0.status == .running }) { text = "Running \(tool.name)... (esc to abort)" }
        else if live.run != nil { text = "Working... (esc to abort)" }
        guard text != statusText else { return }
        statusText = text
        indicator?.dispose()
        indicator = text.isEmpty ? nil : WorkingStatusIndicator(ui: ui, message: text, colorFn: { [weak self] in self?.editor.borderColor($0) ?? $0 })
        editor.setWorkingStatusIndicator(indicator)
    }
    private func syncFooter(_ view: DurableView) {
        let agent = agentOf(view.conversation)
        let usage = totalUsage(view.conversation.docs["pi.usage"].flatMap { try? JSONValue.object($0).decode(UsageState.self) } ?? UsageState())
        var stats: [String] = []
        if usage.input != 0 { stats.append("↑\(formatTokens(usage.input))") }
        if usage.output != 0 { stats.append("↓\(formatTokens(usage.output))") }
        if usage.cacheRead != 0 { stats.append("R\(formatTokens(usage.cacheRead))") }
        if usage.cacheWrite != 0 { stats.append("W\(formatTokens(usage.cacheWrite))") }
        stats.append(String(format: "$%.3f", usage.cost.total))
        let window = view.models.first { $0.provider == agent.model?.provider && $0.modelId == agent.model?.modelId }?.contextWindow ?? 0
        if window > 0 {
            let percent = contextTokens(view.conversation.entries).map { Double($0) / Double(window) * 100 }
            let text = (percent.map { String(format: "%.1f", $0) } ?? "?") + "%/\(formatTokens(window))"
            stats.append((percent ?? 0) > 90 ? theme.fg(.error, text) : text)
        }
        footerStats.setText(theme.fg(.dim, stats.joined(separator: " ") + "  " + view.session.cwd))
        let model = agent.model.map { "\($0.provider)/\($0.modelId)" } ?? "no model"
        let label = view.conversations.first { $0.id == view.conversation.conversation.id }?.label ?? "conversation \(view.conversation.conversation.id.rawValue)"
        footerHints.setText(theme.fg(label == "main" ? .dim : .accent, label) + theme.fg(.dim,
            " · \(model) · thinking:\(agent.thinkingLevel?.rawValue ?? "off") (\(keyText(.cycleThinkingLevel))) · \(keyText(.selectModel)) or /model · /agents · /compact · /tasks · \(keyText(.followUp)) follow-up · \(keyText(.clear)) exit"))
    }
    private func syncTranscript(_ entries: [EntryRecord]) {
        if renderedEntryIds.enumerated().contains(where: { index, id in index >= entries.count || entries[index].id != id }) { rebuild(entries) }
        for entry in entries.dropFirst(renderedEntryIds.count) {
            addEntry(entry)
            renderedEntryIds.append(entry.id)
        }
    }
    private func rebuild(_ entries: [EntryRecord]) {
        chat.clear()
        discardTools()
        summaries.removeAll()
        rebuilt = true
        renderedEntryIds.removeAll()
        streaming = nil
        for entry in entries {
            addEntry(entry)
            renderedEntryIds.append(entry.id)
        }
    }
    private func addEntry(_ entry: EntryRecord) {
        let message = durableMessage(entry.model?.first)
        switch (entry.kind, message) {
        case ("pi.user", .user(let user)):
            chat.addChild(UserMessageComponent(text: userText(user.content)))
        case ("pi.assistant", .assistant(let message)):
            let component = streaming ?? AssistantMessageComponent()
            if streaming == nil { chat.addChild(component) }
            streaming = nil
            component.setStreaming(false)
            component.updateContent(message)
            let ran = message.stopReason == .toolUse
            for case .toolCall(let call) in message.content {
                let streamed = streamingCalls.contains(call.id)
                if !ran && !streamed { continue }
                let card = tool(call.name, callId: call.id, args: call.arguments, fresh: !streamed)
                card.setArgsComplete()
                if !ran {
                    card.updateResult(ToolResultMessage(toolCallId: call.id, toolName: call.name,
                        content: [.text(TextContent(text: "Not run: the answer was interrupted."))], isError: true))
                }
            }
            streamingCalls.removeAll()
        case ("pi.tool-result", .toolResult(let result)):
            tool(result.toolName, callId: result.toolCallId).updateResult(result)
        case ("pi.compaction", _):
            let text: String
            if case .user(let user) = message { text = userText(user.content) } else { text = "" }
            let summary = CompactionComponent(summary: text, expanded: expanded)
            summaries.append(summary)
            chat.addChild(Spacer(1))
            chat.addChild(summary)
        case ("pi.reset", _):
            chat.addChild(Spacer(1))
            chat.addChild(Text(theme.fg(.muted, "[new context]"), paddingX: 1, paddingY: 0))
        default: break
        }
    }
    private func syncStreaming(_ message: AssistantMessage) {
        if streaming == nil {
            streaming = AssistantMessageComponent()
            chat.addChild(streaming!)
        }
        streaming?.setStreaming(true)
        streaming?.updateContent(message)
        for case .toolCall(let call) in message.content {
            _ = tool(call.name, callId: call.id, args: call.arguments, fresh: !streamingCalls.contains(call.id))
            streamingCalls.insert(call.id)
        }
    }
    private func tool(_ name: String, callId: String, args: [String: AnyCodable]? = nil, fresh: Bool = false) -> ToolExecutionComponent {
        if !fresh, let existing = tools[callId] {
            if let args { existing.updateArgs(args) }
            return existing
        }
        let component = ToolExecutionComponent(toolName: name, toolCallId: callId, args: args ?? [:], renderers: Self.renderers[name], ui: ui, cwd: cwd)
        component.setExpanded(expanded)
        chat.addChild(component)
        cards.append(component)
        cardCalls.append((name, callId))
        tools[callId] = component
        return component
    }
}
