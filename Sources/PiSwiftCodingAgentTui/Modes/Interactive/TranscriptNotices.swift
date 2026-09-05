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

func assistantDiagnosticNotices(_ message: AssistantMessage) -> [String] {
    (message.diagnostics ?? []).compactMap { diagnostic in
        guard diagnostic.type == "anthropic_input_transformations",
              let transformations = diagnostic.details["transformations"]?.value as? [[String: Any]] else { return nil }
        let dropped = transformations.compactMap { item -> String? in
            guard item["type"] as? String == "thinking_dropped" else { return nil }
            let reason = item["reason"] as? String ?? "unknown reason"
            let path = (item["path"] as? String).map { " at \($0)" } ?? ""
            return reason + path
        }
        guard !dropped.isEmpty else { return nil }
        let noun = dropped.count == 1 ? "thinking block" : "\(dropped.count) thinking blocks"
        return "Anthropic dropped \(noun): \(dropped.joined(separator: "; "))"
    }
}

/// Swift's session manager exposes messages, not context entries. Retain the entry metadata
/// needed by the transcript while using the same compaction boundary as buildSessionContext.
func interactiveContextEntries(_ sessionManager: SessionManager) -> [SessionEntry] {
    let branch = sessionManager.getBranch()
    guard let index = branch.lastIndex(where: { if case .compaction = $0 { return true }; return false }),
          case .compaction(let compaction) = branch[index] else { return branch }
    let kept = branch[..<index].firstIndex { $0.id == compaction.firstKeptEntryId }
    return [branch[index]] + (kept.map { Array(branch[$0..<index]) } ?? []) + Array(branch.dropFirst(index + 1))
}
