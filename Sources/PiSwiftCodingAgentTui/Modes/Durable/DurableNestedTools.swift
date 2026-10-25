import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable

/// Call IDs are opaque. Compare their bytes without Unicode normalization.
struct DurableNestedToolParent: Hashable {
    let taskId: TaskID
    let callId: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.taskId == rhs.taskId && lhs.callId.utf8.elementsEqual(rhs.callId.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(taskId)
        hasher.combine(Array(callId.utf8))
    }
}

/// Shows live nested calls. These cards do not enter the transcript.
@MainActor
final class DurableNestedTools {
    let container = Container()
    private(set) var cards: [TaskID: ToolExecutionComponent] = [:]
    private(set) var groups: [DurableNestedToolParent: [TaskID]] = [:]
    private var slots: [TaskID: NestedToolSlot] = [:]
    private let ui: TUI
    private let cwd: String

    init(ui: TUI, cwd: String) {
        self.ui = ui
        self.cwd = cwd
    }

    func apply(_ live: LiveState, expanded: Bool, completedParents: Set<DurableNestedToolParent> = []) {
        let nested = live.nestedTools ?? []
        let all = Dictionary(nested.map { ($0.taskId, $0) }, uniquingKeysWith: { _, newest in newest })
        var settled = Set((live.tools ?? []).filter { $0.status == .done }.compactMap { slot in
            slot.taskId.map { DurableNestedToolParent(taskId: $0, callId: slot.callId) }
        })
        // The transcript result can arrive before the live document is cleared.
        settled.formUnion(completedParents)
        // Do not retain descendants of a caller that has finished.
        settled.formUnion(nested.filter { $0.status == .done }.map {
            DurableNestedToolParent(taskId: $0.taskId, callId: $0.callId)
        })
        var hidden: Set<TaskID> = []
        for slot in nested {
            var parent = DurableNestedToolParent(taskId: slot.parentTaskId, callId: slot.parentCallId)
            var visited: Set<TaskID> = [slot.taskId]
            while visited.insert(parent.taskId).inserted {
                if settled.contains(parent) { hidden.insert(slot.taskId); break }
                guard let ancestor = all[parent.taskId],
                      ancestor.callId.utf8.elementsEqual(parent.callId.utf8) else { break }
                parent = DurableNestedToolParent(taskId: ancestor.parentTaskId, callId: ancestor.parentCallId)
            }
        }
        let visible = all.filter { !hidden.contains($0.key) }
        for id in Array(cards.keys) where visible[id] == nil { discard(id) }
        slots = visible
        for slot in slots.values {
            let card: ToolExecutionComponent
            if let current = cards[slot.taskId] { card = current }
            else {
                card = ToolExecutionComponent(toolName: slot.name, toolCallId: slot.callId,
                    args: [:], ui: ui, cwd: cwd)
                cards[slot.taskId] = card
            }
            let foundation = (try? foundationJSON(from: .object(slot.arguments))) as? [String: Any] ?? [:]
            let arguments = foundation.mapValues(AnyCodable.init)
            card.updateArgs(arguments)
            card.setArgsComplete()
            card.setExpanded(expanded)
            if slot.status == .running { card.markExecutionStarted() }
            let output = slot.status == .done ? "" : slot.output ?? ""
            card.updateResult(ToolResultMessage(toolCallId: slot.callId, toolName: slot.name,
                content: output.isEmpty ? [] : [.text(TextContent(text: output))],
                details: slot.status == .done ? nil : slot.details.flatMap { try? AnyCodable(foundationJSON(from: $0)) },
                isError: slot.summary?.isError ?? false, durationMs: slot.summary?.durationMs),
                isPartial: slot.status != .done)
        }
        renderGroups()
    }

    func setExpanded(_ expanded: Bool) {
        for card in cards.values { card.setExpanded(expanded) }
        renderGroups()
    }

    func clear() {
        for id in Array(cards.keys) { discard(id) }
        slots.removeAll()
        groups.removeAll()
        container.clear()
    }

    private func discard(_ id: TaskID) {
        guard let card = cards.removeValue(forKey: id), let slot = slots[id] else { return }
        // Complete the renderer before removal so that its timer stops.
        card.updateResult(ToolResultMessage(toolCallId: slot.callId, toolName: slot.name,
                                           content: [], isError: false))
    }

    private func renderGroups() {
        container.clear()
        groups.removeAll()
        let ordered = slots.values.sorted { $0.taskId < $1.taskId }
        var children: [TaskID: [TaskID]] = [:]
        var parents: [DurableNestedToolParent] = []
        for slot in ordered {
            if let parent = slots[slot.parentTaskId],
               parent.callId.utf8.elementsEqual(slot.parentCallId.utf8) {
                children[parent.taskId, default: []].append(slot.taskId)
            } else {
                let parent = DurableNestedToolParent(taskId: slot.parentTaskId, callId: slot.parentCallId)
                if groups[parent] == nil { parents.append(parent) }
                groups[parent, default: []].append(slot.taskId)
            }
        }
        var shown: Set<TaskID> = []
        for parent in parents {
            container.addChild(Spacer(1))
            container.addChild(Text(theme.fg(.muted,
                "Nested tools for #\(parent.taskId.rawValue) (\(parent.callId))"), paddingX: 1, paddingY: 0))
            var pending = (groups[parent] ?? []).reversed().map { ($0, 0) }
            while let (id, depth) = pending.popLast() {
                guard shown.insert(id).inserted, let slot = slots[id], let card = cards[id] else { continue }
                let box = Box(paddingX: 2 * (depth + 1), paddingY: 0)
                box.addChild(Text(theme.fg(.muted, "#\(id.rawValue) · \(slot.status.rawValue)"), paddingX: 0, paddingY: 0))
                box.addChild(card)
                for line in information(slot) { box.addChild(Text(line, paddingX: 1, paddingY: 0)) }
                container.addChild(box)
                pending.append(contentsOf: (children[id] ?? []).reversed().map { ($0, depth + 1) })
            }
        }
    }

    private func information(_ slot: NestedToolSlot) -> [String] {
        if slot.status == .done {
            guard let summary = slot.summary else { return [theme.fg(.muted, "Done")] }
            var status = summary.isError ? "Failed" : "Done"
            if let duration = summary.durationMs { status += " · \(duration) ms" }
            if let usage = summary.usage {
                status += " · ↑\(usage.input) ↓\(usage.output) R\(usage.cacheRead) W\(usage.cacheWrite)"
            }
            var lines = [theme.fg(summary.isError ? .error : .muted, status)]
            if let error = summary.error { lines.append(theme.fg(.error, error)) }
            return lines
        }
        var lines: [String] = []
        if let details = slot.details, let text = try? details.jsonText() {
            lines.append(theme.fg(.muted, "Details: \(text)"))
        }
        for diagnostic in slot.diagnostics ?? [] {
            let color: ThemeColor = diagnostic.severity == .error ? .error : diagnostic.severity == .warn ? .warning : .muted
            let code = diagnostic.code.map { " [\($0)]" } ?? ""
            lines.append(theme.fg(color, "\(diagnostic.severity.rawValue)\(code): \(diagnostic.message)"))
        }
        if (slot.droppedBytes ?? 0) > 0 || (slot.droppedLines ?? 0) > 0 {
            lines.append(theme.fg(.muted,
                "Output removed: \(slot.droppedBytes ?? 0) bytes, \(slot.droppedLines ?? 0) lines"))
        }
        return lines
    }
}
