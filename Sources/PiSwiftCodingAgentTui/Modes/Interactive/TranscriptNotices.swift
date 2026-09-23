import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

func summaryCostNotice(usage: Usage, branch: Bool = false) -> String {
    let tokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
    let count: String
    if tokens < 1_000 { count = "\(tokens)" }
    else if tokens < 10_000 { count = String(format: "%.1fk", Double(tokens) / 1_000) }
    else if tokens < 1_000_000 { count = "\(Int(round(Double(tokens) / 1_000)))k" }
    else if tokens < 10_000_000 { count = String(format: "%.1fM", Double(tokens) / 1_000_000) }
    else { count = "\(Int(round(Double(tokens) / 1_000_000)))M" }
    let cost = usage.cost.total >= 0.01 ? String(format: " (~$%.2f)", usage.cost.total) : ""
    return "\(branch ? "Branch summary" : "Compaction"): \(count) tokens billed\(cost)"
}

func thinkingDropNoticeText(_ notice: ThinkingDropNotice) -> String {
    let noun = notice.count == 1 ? "thinking block" : "thinking blocks"
    return "Anthropic dropped \(notice.count) \(noun) (details in session)"
}

func interactiveContextEntries(_ sessionManager: SessionManager) -> [SessionEntry] {
    sessionManager.buildContextEntries()
}

func thinkingDropNoticesByEntryID(_ branch: [SessionEntry]) -> [String: ThinkingDropNotice] {
    var previous: AssistantMessage?
    var notices: [String: ThinkingDropNotice] = [:]
    for entry in branch {
        guard case .message(let messageEntry) = entry,
              case .assistant(let current) = messageEntry.message else { continue }
        if let notice = newThinkingDropNotice(current: current, previous: previous) {
            notices[entry.id] = notice
        }
        previous = current
    }
    return notices
}
