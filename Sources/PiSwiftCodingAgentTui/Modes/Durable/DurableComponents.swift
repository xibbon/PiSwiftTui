import MiniTui
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable

/// A filtered list that replaces the editor.
@MainActor
final class ListSelector: Container, Focusable {
    private let input = Input()
    private let listContainer = Container()
    private let items: [SelectItem]
    private let onSelect: (String) -> Void
    private let onCancel: () -> Void
    private var list: SelectList!
    var focused = false { didSet { input.focused = focused } }

    init(title: String, items: [SelectItem], onSelect: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.items = items
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init()
        build(items)
        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, theme.bold(title)), paddingX: 1, paddingY: 0))
        addChild(input)
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(DynamicBorder())
    }

    override func handleInput(_ data: String) {
        let keys = getKeybindings()
        if [TUIKeybinding.selectUp, TUIKeybinding.selectDown, TUIKeybinding.selectConfirm, TUIKeybinding.selectCancel].contains(where: { keys.matches(data, $0) }) {
            list.handleInput(data)
            return
        }
        input.handleInput(data)
        let query = input.getValue()
        build(query.isEmpty ? items : fuzzyFilter(items, query: query, getText: { "\($0.label) \($0.value)" }))
    }

    private func build(_ items: [SelectItem]) {
        let selectTheme = SelectListTheme(
            selectedPrefix: { theme.fg(.accent, $0) }, selectedText: { theme.fg(.accent, $0) },
            description: { theme.fg(.muted, $0) }, scrollInfo: { theme.fg(.dim, $0) },
            noMatch: { theme.fg(.warning, $0) })
        list = SelectList(items: items, maxVisible: 10, theme: selectTheme)
        list.onSelect = { [weak self] in self?.onSelect($0.value) }
        list.onCancel = onCancel
        listContainer.clear()
        listContainer.addChild(list)
    }
}

/// The summary that replaced earlier context.
@MainActor
final class CompactionComponent: Box {
    private let summary: String
    init(summary: String, expanded: Bool) {
        self.summary = summary
        super.init(paddingX: 1, paddingY: 1, bgFn: { theme.bg(.customMessageBg, $0) })
        setExpanded(expanded)
    }
    func setExpanded(_ expanded: Bool) {
        clear()
        addChild(Text(theme.fg(.customMessageLabel, theme.bold("[compaction]")), paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        if expanded {
            addChild(Markdown(summary, paddingX: 0, paddingY: 0, theme: getMarkdownTheme(),
                              defaultTextStyle: DefaultTextStyle(color: { theme.fg(.customMessageText, $0) })))
        } else {
            addChild(Text(theme.fg(.customMessageText, "Earlier context summarized (") +
                          theme.fg(.dim, keyText(.expandTools)) + theme.fg(.customMessageText, " to expand)"),
                          paddingX: 0, paddingY: 0))
        }
    }
}

func describeTask(_ node: TaskGraphNode) -> String {
    let status: String
    switch node.state {
    case .waiting(_, let on, _): status = "waiting on " + on.map { String($0.rawValue) }.joined(separator: ", ")
    case .completing(let outcome): status = "completing (\(outcome))"
    case .pending(let phase), .running(let phase): status = "\(node.state.status) \(phase)"
    }
    let flags = [node.background ? "background" : "", node.abortRequested ? "aborting" : ""].filter { !$0.isEmpty }
    let owned = node.conversations.isEmpty ? "" : " owns conversation " + node.conversations.map { String($0.rawValue) }.joined(separator: ", ")
    return "\(node.kind) #\(node.id.rawValue): \(status)" + (flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]") + owned
}

func userText(_ content: UserContent) -> String {
    switch content {
    case .text(let text): text
    case .blocks(let blocks): blocks.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined()
    }
}

func userText(_ content: JSONValue?) -> String {
    if let text = content?.stringValue { return text }
    return (content?.arrayValue ?? []).compactMap { block -> String? in
        guard let object = block.objectValue, object["type"] == .string("text") else { return nil }
        return object["text"]?.stringValue
    }.joined()
}

func totalUsage(_ state: UsageState) -> Usage {
    var total = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
    for usage in Array(state.models.values) + Array(state.tools.values) {
        total.input += usage.input
        total.output += usage.output
        total.cacheRead += usage.cacheRead
        total.cacheWrite += usage.cacheWrite
        total.cost.total += usage.cost.total
    }
    return total
}

func contextTokens(_ entries: [EntryRecord]) -> Int? {
    let compacted = entries.filter { $0.kind == "pi.compaction" }.map { $0.id.rawValue }.max() ?? 0
    for entry in entries.reversed() {
        guard entry.id.rawValue >= compacted, entry.kind == "pi.assistant",
              case .assistant(let message) = durableMessage(entry.model?.first),
              message.stopReason != .aborted, message.stopReason != .error else { continue }
        let usage = message.usage
        return usage.totalTokens != 0 ? usage.totalTokens : usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    }
    return nil
}

/// Use the same Foundation and ordered bridges as EntryRecord.messages().
func durableAssistant(_ object: JSONObject?) -> AssistantMessage? {
    guard let object, case .assistant(let message) = durableMessage(.object(object)) else { return nil }
    return message
}

func durableMessage(_ value: JSONValue?) -> Message? {
    guard let value, let foundation = try? foundationJSON(from: value) as? [String: Any],
          let ordered = try? orderedJSON(from: value) else { return nil }
    return messageFromJSONObject(foundation, ordered: ordered)
}
