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
    var loadEarlier: () -> Void = {}
    var fillGap: (TranscriptGap) -> Void = { _ in }
    var refresh: () -> Void = {}
}

@MainActor
final class DurableTui {
    private static let renderers = createDurableToolRenderers()
    let ui: TUI
    let renderer: AltScreenRenderer
    let layoutRoot = VStack()
    let chat = Container()
    let liveContent = Container()
    let nestedTools: DurableNestedTools
    let status = Container()
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
    private var completedCalls: Set<[UInt8]> = []
    private var unclaimedLiveCalls: Set<[UInt8]> = []
    private var liveParents: [[UInt8]: DurableNestedToolParent] = [:]
    private var conversationId: ConversationID?
    private(set) var summaries: [CompactionComponent] = []
    private(set) var expanded = false
    private var rowComponents: [DurableTranscriptRow.ID: Container] = [:]
    private var rowItems: [DurableTranscriptRow.ID: TranscriptItem] = [:]
    private var rowOrder: [DurableTranscriptRow.ID] = []
    private var rowTarget: Container?
    private(set) var rowConstructionCount = 0
    private var streaming: AssistantMessageComponent?
    private(set) var indicator: WorkingStatusIndicator?
    private var statusText = ""
    private var rebuilt = false
    private(set) var terminalState: DurableSessionTerminal?
    let transcript: ScrollView

    init(cwd: String, handlers: DurableTuiHandlers, terminal: any Terminal = ProcessTerminal()) {
        self.cwd = cwd
        ui = TUI(terminal: terminal, showHardwareCursor: false, logDirectory: getAgentDir())
        renderer = ui.enableAltScreen()
        nestedTools = DurableNestedTools(ui: ui, cwd: cwd)
        let keybindings = KeybindingsManager.create()
        editor = CustomEditor(ui: ui, theme: getEditorTheme(), keybindings: keybindings,
                              options: EditorOptions(paddingX: 1), embedWorkingStatus: true)
        let content = Container()
        content.addChild(chat)
        chat.addChild(liveContent)
        content.addChild(nestedTools.container)
        content.addChild(Spacer(1))
        transcript = ScrollView(content, options: ScrollViewOptions(follow: .end, primary: true, overscroll: .chain))
        editor.onSubmit = handlers.submit
        editor.onHookShortcut = { data in
            switch data {
            case "\u{05}": handlers.loadEarlier(); return true
            case "\u{12}": handlers.refresh(); return true
            default: return false
            }
        }
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
            nestedTools.setExpanded(expanded)
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
        let dock = VStack(children: [status, tasks, queue, notices, editorContainer, footer].map {
            .entry(StackEntry($0, options: StackEntryOptions(shrink: 1, minSize: $0 === editorContainer ? 3 : 0)))
        })
        for component in [chat, status, tasks, queue, notices, editorContainer, footer] { ui.addChild(component) }
        layoutRoot.addChild(transcript, options: StackEntryOptions(basis: .points(0), grow: 1, shrink: 1, minSize: 1))
        layoutRoot.addChild(dock, options: StackEntryOptions(basis: .auto, grow: 0, shrink: 1, minSize: 1))
        renderer.setLayoutRoot(layoutRoot)
        ui.switchRenderer(to: .altScreen)
        ui.setFocus(editor)
    }

    func start() { ui.start() }
    func resetForReopen() {
        terminalState = nil
        statusText = ""
        indicator?.dispose()
        indicator = nil
        editor.setWorkingStatusIndicator(nil)
        chat.clear()
        liveContent.clear()
        discardTools()
        nestedTools.clear()
        summaries.removeAll()
        rowComponents.removeAll()
        rowItems.removeAll()
        rowOrder.removeAll()
        chat.addChild(liveContent)
        conversationId = nil
        streaming = nil
        rebuilt = true
    }
    func stop() {
        discardTools()
        nestedTools.clear()
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
        completedCalls.removeAll()
        unclaimedLiveCalls.removeAll()
        liveParents.removeAll()
    }
    func mount(_ component: any Component) {
        editorContainer.clear()
        editorContainer.addChild(component)
        ui.setFocus(component)
        ui.requestRender()
    }
    func restoreEditor() { mount(editor) }

    func apply(_ view: DurableHostView) {
        if terminalState == nil { terminalState = view.terminal }
        notices.clear()
        let previous = conversationId
        conversationId = view.transcript.conversation.id
        if let previous, previous != conversationId {
            chat.clear()
            liveContent.clear()
            discardTools()
            nestedTools.clear()
            summaries.removeAll()
            rowComponents.removeAll()
            rowItems.removeAll()
            rowOrder.removeAll()
            streaming = nil
            rebuilt = true
        }
        syncTranscript(view.rows)
        syncLive(view.live)
        syncStatus(view)
        syncTasks(view.tasks, outcomes: view.outcomes)
        syncQueue(view.inbox, runActive: view.live.run != nil)
        if let ending = view.ending {
            let card = Box(paddingX: 1, paddingY: 0, bgFn: { theme.bg(.customMessageBg, $0) })
            card.addChild(Text(theme.fg(.warning, theme.bold(ending.text)), paddingX: 0, paddingY: 0))
            card.addChild(Text(theme.fg(.customMessageText, ending.explanation), paddingX: 0, paddingY: 0))
            if let detail = ending.detail {
                card.addChild(Text(theme.fg(.muted, detail), paddingX: 0, paddingY: 0))
            }
            card.addChild(Text(theme.fg(.accent, ending.action), paddingX: 0, paddingY: 0))
            notices.addChild(card)
        }
        if let error = view.documentError { showError(error) }
        for item in view.notices.suffix(4) {
            if case .failed(let message) = terminalState,
               item.category == .sessionFailed || (item.category == .operation && item.message == message) { continue }
            let color: ThemeColor = item.level == .error ? .error : item.level == .warning ? .warning : .muted
            notices.addChild(Text(theme.fg(color, describeNotice(item)), paddingX: 1, paddingY: 0))
        }
        if case .failed(let message) = terminalState {
            showError("Session failed: \(message) · /reopen or Ctrl-D to quit")
        } else if terminalState == .closed {
            notices.addChild(Text(theme.fg(.muted, "Session closed"), paddingX: 1, paddingY: 0))
        }
        let level = view.agent.thinkingLevel?.rawValue ?? "off"
        editor.borderColor = { theme.getThinkingBorderColor(level)($0) }
        syncFooter(view)
        if rebuilt { transcript.scrollToEnd() }
        // The dock height changes when queue items and notices arrive.
        layoutRoot.invalidate()
        ui.requestRender(force: rebuilt || terminalState != nil)
        rebuilt = false
    }

    func showError(_ message: String) {
        notices.addChild(Text(theme.fg(.error, message), paddingX: 1, paddingY: 0))
        layoutRoot.invalidate()
        ui.requestRender()
    }

    private func syncLive(_ live: LiveState) {
        let message = durableAssistant(live.generation?.message)
        if message == nil, let partial = streaming {
            liveContent.removeChild(partial)
            streaming = nil
        }
        if let message { syncStreaming(message) }
        for slot in live.tools ?? [] where slot.status != .pending {
            let callId = Array(slot.callId.utf8)
            if let taskId = slot.taskId, liveParents[callId] == nil {
                liveParents[callId] = DurableNestedToolParent(taskId: taskId, callId: slot.callId)
            }
            guard !completedCalls.contains(callId) else { continue }
            let needsAssistant = tools[slot.callId] == nil
            let component = tool(slot.name, callId: slot.callId)
            if needsAssistant { unclaimedLiveCalls.insert(callId) }
            component.setArgsComplete()
            guard slot.status == .running else { continue }
            component.markExecutionStarted()
            let child = slot.details?.objectValue?["conversationId"]?.numberValue
            let output = slot.output ?? child.map { "Subagent \(Int($0)) is working. /agents switches to it." }
            if output != nil || slot.name == "codemode" {
                component.updateResult(ToolResultMessage(toolCallId: slot.callId, toolName: slot.name,
                    content: output.map { [.text(TextContent(text: $0))] } ?? [],
                    details: slot.details.flatMap { try? AnyCodable(foundationJSON(from: $0)) }, isError: false), isPartial: true)
            }
        }
        let completedParents = Set(completedCalls.compactMap { liveParents[$0] })
        nestedTools.apply(live, expanded: expanded, completedParents: completedParents)
        if let failure = live.compactionFailure {
            showError("Compaction failed (\(failure.reason.rawValue), task #\(failure.taskId.rawValue)): \(failure.error)")
        }
    }

    private func syncTasks(_ graph: TaskGraph?, outcomes: [DurableTaskOutcome]) {
        tasks.clear()
        guard let graph else {
            for outcome in outcomes.suffix(4) {
                tasks.addChild(Text(theme.fg(.muted, "\(outcome.kind) #\(outcome.id.rawValue): \(outcome.outcome)"), paddingX: 1, paddingY: 0))
            }
            return
        }
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
        for line in lines { tasks.addChild(Text(theme.fg(.muted, line), paddingX: 1, paddingY: 0)) }
        for outcome in outcomes.suffix(4) {
            tasks.addChild(Text(theme.fg(.muted, "\(outcome.kind) #\(outcome.id.rawValue): \(outcome.outcome)"), paddingX: 1, paddingY: 0))
        }
    }
    private func syncQueue(_ inbox: InboxState, runActive: Bool) {
        queue.clear()
        let items = inbox.items
        if !runActive, items.contains(where: { $0.mode != .write }) {
            queue.addChild(Text(theme.fg(.muted, "Queued inputs (no active run):"), paddingX: 1, paddingY: 0))
        }
        for item in items {
            let text: String
            if let entry = item.entry {
                text = applicationEntryText(kind: entry.kind, data: entry.data, model: entry.model)
            } else if let entry = item.inputEntry {
                text = "<\(entry.kind)> \(userText(item.content))" + (entry.data.map { " · \(shortData($0))" } ?? "")
            } else { text = userText(item.content) }
            queue.addChild(TruncatedText(theme.fg(.muted, "[\(item.mode.rawValue)] \(text)"), paddingX: 1, paddingY: 0))
        }
    }
    private func syncStatus(_ view: DurableHostView) {
        status.clear()
        var text = ""
        if terminalState == nil {
            for task in view.sleepingTasks {
                let time = Date(timeIntervalSince1970: task.until / 1000).ISO8601Format()
                status.addChild(Text(theme.fg(.muted, "\(task.kind) #\(task.id.rawValue): waiting until \(time) (\(task.phase))"), paddingX: 1, paddingY: 0))
            }
        }
        let canProgress = terminalState == nil && view.activity == .progressing
        let live = view.live
        if canProgress {
            if let retry = live.generation?.retry {
                text = "Retrying (attempt \((live.generation?.attempt ?? 0) + 1)): \(retry.error)"
            } else if live.generation?.deferred != nil { text = "Waiting for deferred response..." }
            else if let compaction = live.compactions?.first {
                text = compaction.retry != nil ? "Retrying \(compaction.reason.rawValue) compaction (attempt \(compaction.attempt + 1))..." : "Compacting (\(compaction.reason.rawValue))..."
            } else if let tool = live.tools?.first(where: { $0.status == .running }) { text = "Running \(tool.name)... (esc to abort)" }
            else if let count = live.run?.afterRun?.tasks?.count, count > 0 { text = "Finishing \(count) after-run tasks... (esc to abort)" }
            else if live.run != nil { text = "Working... (esc to abort)" }
        }
        if canProgress, text.isEmpty { text = "Working... (esc to abort)" }
        if terminalState == nil && view.openMode == .readOnly {
            status.addChild(Text(theme.fg(.warning, "Read-only · /refresh to see new entries"), paddingX: 1, paddingY: 0))
        }
        if terminalState == nil, let turns = live.run?.turns {
            status.addChild(Text(theme.fg(.muted, "Turn \(turns)"), paddingX: 1, paddingY: 0))
        }
        guard text != statusText else { return }
        statusText = text
        indicator?.dispose()
        indicator = text.isEmpty ? nil : WorkingStatusIndicator(ui: ui, message: text, colorFn: { [weak self] in self?.editor.borderColor($0) ?? $0 })
        editor.setWorkingStatusIndicator(indicator)
    }
    private func syncFooter(_ view: DurableHostView) {
        let agent = view.agent
        let usage = totalUsage(view.usage)
        var stats: [String] = []
        if usage.input != 0 { stats.append("↑\(formatTokens(usage.input))") }
        if usage.output != 0 { stats.append("↓\(formatTokens(usage.output))") }
        if usage.cacheRead != 0 { stats.append("R\(formatTokens(usage.cacheRead))") }
        if usage.cacheWrite != 0 { stats.append("W\(formatTokens(usage.cacheWrite))") }
        stats.append(String(format: "$%.3f", usage.cost.total))
        let window = view.models.first { $0.provider == agent.model?.provider && $0.modelId == agent.model?.modelId }?.contextWindow ?? 0
        if window > 0 {
            let entries = view.rows.compactMap { row -> EntryRecord? in
                if case .entry(let entry) = row.item { return entry }
                return nil
            }
            let percent = contextTokens(entries).map { Double($0) / Double(window) * 100 }
            let text = (percent.map { String(format: "%.1f", $0) } ?? "?") + "%/\(formatTokens(window))"
            stats.append((percent ?? 0) > 90 ? theme.fg(.error, text) : text)
        }
        footerStats.setText(theme.fg(.dim, stats.joined(separator: " ") + "  " + view.session.cwd))
        let model = agent.model.map { "\($0.provider)/\($0.modelId)" } ?? "no model"
        let label = view.conversations.first { $0.id == view.transcript.conversation.id }?.label ?? "conversation \(view.transcript.conversation.id.rawValue)"
        footerHints.setText(theme.fg(label == "main" ? .dim : .accent, label) + theme.fg(.dim,
            " · \(model) · thinking:\(agent.thinkingLevel?.rawValue ?? "off") (\(keyText(.cycleThinkingLevel))) · \(keyText(.selectModel)) or /model · /agents · /compact · /tasks · /continue · /earlier · /refresh · /abort <id> · \(keyText(.followUp)) follow-up · \(keyText(.clear)) exit"))
    }
    private func syncTranscript(_ rows: [DurableTranscriptRow]) {
        let ids = rows.map(\.id)
        let held = Set(ids)
        for id in rowComponents.keys where !held.contains(id) {
            rowComponents.removeValue(forKey: id)
            rowItems.removeValue(forKey: id)
        }
        var changed = ids != rowOrder
        for row in rows where rowItems[row.id] != row.item {
            let container = Container()
            rowTarget = container
            switch row.item {
            case .entry(let entry): addEntry(entry)
            case .earlier:
                container.addChild(Text(theme.fg(.accent, "… Earlier entries available · /earlier or Ctrl-E to load …"), paddingX: 1, paddingY: 0))
            case .gap:
                container.addChild(Text(theme.fg(.warning,
                    "… Entries in this range not loaded · /gap to load …"), paddingX: 1, paddingY: 0))
            }
            rowTarget = nil
            rowComponents[row.id] = container
            rowItems[row.id] = row.item
            rowConstructionCount += 1
            changed = true
        }
        if changed {
            chat.clear()
            for id in ids {
                if let component = rowComponents[id] { chat.addChild(component) }
            }
            chat.addChild(liveContent)
            rowOrder = ids
            rebuilt = true
        }
    }
    private func addEntry(_ entry: EntryRecord) {
        let message = durableMessage(entry.model?.first)
        switch (entry.kind, message) {
        case ("pi.user", .user(let user)):
            rowTarget?.addChild(UserMessageComponent(text: userText(user.content)))
        case ("pi.assistant", .assistant(let message)):
            let component = streaming ?? AssistantMessageComponent()
            if streaming != nil { liveContent.removeChild(component) }
            rowTarget?.addChild(component)
            streaming = nil
            component.setStreaming(false)
            component.updateContent(message)
            let ran = message.stopReason == .toolUse
            for case .toolCall(let call) in message.content {
                let streamed = streamingCalls.contains(call.id)
                if !ran && !streamed { continue }
                let card = tool(call.name, callId: call.id, args: call.arguments,
                                fresh: !streamed && !unclaimedLiveCalls.contains(Array(call.id.utf8)))
                unclaimedLiveCalls.remove(Array(call.id.utf8))
                card.setArgsComplete()
                if !ran {
                    card.updateResult(ToolResultMessage(toolCallId: call.id, toolName: call.name,
                        content: [.text(TextContent(text: "Not run: the answer was interrupted."))], isError: true))
                }
            }
            streamingCalls.removeAll()
        case ("pi.tool-result", .toolResult(let result)):
            tool(result.toolName, callId: result.toolCallId).updateResult(result)
            completedCalls.insert(Array(result.toolCallId.utf8))
        case ("pi.compaction", _):
            let text: String
            if case .user(let user) = message { text = userText(user.content) } else { text = "" }
            let summary = CompactionComponent(summary: text, expanded: expanded)
            summaries.append(summary)
            rowTarget?.addChild(Spacer(1))
            rowTarget?.addChild(summary)
        case ("pi.reset", _):
            rowTarget?.addChild(Spacer(1))
            rowTarget?.addChild(Text(theme.fg(.muted, "[new context]"), paddingX: 1, paddingY: 0))
        default:
            rowTarget?.addChild(Spacer(1))
            rowTarget?.addChild(Text(theme.fg(.customMessageText,
                applicationEntryText(kind: entry.kind, data: entry.data, model: entry.model)), paddingX: 1, paddingY: 0))
        }
    }
    private func syncStreaming(_ message: AssistantMessage) {
        if streaming == nil {
            streaming = AssistantMessageComponent()
            liveContent.addChild(streaming!)
        }
        streaming?.setStreaming(true)
        streaming?.updateContent(message)
        for case .toolCall(let call) in message.content {
            _ = tool(call.name, callId: call.id, args: call.arguments,
                     fresh: !streamingCalls.contains(call.id) && !unclaimedLiveCalls.contains(Array(call.id.utf8)))
            unclaimedLiveCalls.remove(Array(call.id.utf8))
            streamingCalls.insert(call.id)
        }
    }
    private func tool(_ name: String, callId: String, args: [String: AnyCodable]? = nil, fresh: Bool = false) -> ToolExecutionComponent {
        if !fresh, let existing = tools[callId] {
            if let args { existing.updateArgs(args) }
            return existing
        }
        let component = ToolExecutionComponent(toolName: name, toolCallId: callId, args: args ?? [:], renderers: Self.renderers[name], ui: ui, cwd: cwd)
        completedCalls.remove(Array(callId.utf8))
        if fresh { liveParents.removeValue(forKey: Array(callId.utf8)) }
        component.setExpanded(expanded)
        (rowTarget ?? liveContent).addChild(component)
        cards.append(component)
        cardCalls.append((name, callId))
        tools[callId] = component
        return component
    }
}
