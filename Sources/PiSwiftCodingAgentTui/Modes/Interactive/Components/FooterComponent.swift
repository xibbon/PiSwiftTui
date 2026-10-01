import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public func formatTokens(_ count: Int) -> String {
    if count < 1000 { return "\(count)" }
    if count < 10000 { return String(format: "%.1fk", Double(count) / 1000) }
    if count < 1_000_000 { return "\(Int(round(Double(count) / 1000)))k" }
    if count < 10_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    return "\(Int(round(Double(count) / 1_000_000)))M"
}

public final class FooterComponent: Component {
    private var session: AgentSession
    private var autoCompactEnabled = true
    private let footerData: FooterDataProviding
    private var bashToolStartDate: Date?

    private struct SessionStats {
        let session: AgentSession
        let sessionId: String
        let leafId: String?
        let entryCount: Int
        let limitsModel: Model
        let usageTotals: UsageTotals
        let latestCacheHitRate: Double?
        let contextUsage: ContextUsage?
    }
    private var sessionStats: SessionStats?
    private(set) var statsScanCount = 0

    public func setSession(_ session: AgentSession) { self.session = session }

    public init(session: AgentSession, footerData: FooterDataProviding) {
        self.session = session
        self.footerData = footerData
    }

    public func setBashToolRunning(_ running: Bool) {
        bashToolStartDate = running ? Date() : nil
    }

    public func setAutoCompactEnabled(_ enabled: Bool) {
        autoCompactEnabled = enabled
    }

    public func invalidate() {
        // Branch cache invalidation handled by FooterDataProvider.
    }

    private func getSessionStats() -> SessionStats {
        let manager = session.sessionManager
        let entryCount = manager.getEntryCount()
        let sessionId = manager.getSessionId()
        let leafId = manager.getLeafId()
        let limitsModel = session.routedModel?.model ?? session.agent.state.model
        if let cached = sessionStats, cached.session === session,
           cached.sessionId == sessionId, cached.leafId == leafId,
           cached.entryCount == entryCount,
           cached.limitsModel.provider == limitsModel.provider,
           cached.limitsModel.id == limitsModel.id,
           cached.limitsModel.api == limitsModel.api,
           cached.limitsModel.contextWindow == limitsModel.contextWindow {
            return cached
        }
        var totals = UsageTotals()
        var latestCacheHitRate: Double?
        for entry in manager.getEntries() {
            let usage: Usage?
            switch entry {
            case .usage(let record): usage = record.usage
            case .message(let record):
                switch record.message {
                case .assistant(let message):
                    usage = message.usage
                    let prompt = message.usage.input + message.usage.cacheRead + message.usage.cacheWrite
                    latestCacheHitRate = prompt > 0 ? Double(message.usage.cacheRead) / Double(prompt) * 100 : nil
                case .toolResult(let result): usage = result.usage
                default: usage = nil
                }
            case .compaction(let summary): usage = summary.usage
            case .branchSummary(let summary): usage = summary.usage
            default: usage = nil
            }
            if let usage { totals.add(usage) }
        }
        statsScanCount += 1
        let stats = SessionStats(session: session, sessionId: sessionId, leafId: leafId,
            entryCount: entryCount, limitsModel: limitsModel, usageTotals: totals,
            latestCacheHitRate: latestCacheHitRate, contextUsage: session.getContextUsage())
        sessionStats = stats
        return stats
    }

    public func render(width: Int) -> [String] {
        let state = session.agent.state
        let stats = getSessionStats()
        let totals = stats.usageTotals
        let contextWindow = stats.contextUsage?.contextWindow ?? stats.limitsModel.contextWindow
        let contextPercentValue = stats.contextUsage?.percent ?? 0
        let contextPercent = stats.contextUsage != nil && stats.contextUsage?.percent == nil ? "?" : String(format: "%.1f", contextPercentValue)

        var pwd = session.sessionManager.getCwd()
        if let home = ProcessInfo.processInfo.environment["HOME"], pwd.hasPrefix(home) {
            pwd = "~" + pwd.dropFirst(home.count)
        }

        if let branch = footerData.getGitBranch() {
            pwd += " (\(branch))"
        }

        if let name = session.sessionManager.getSessionName() { pwd += " • \(name)" }
        if visibleWidth(pwd) > width {
            pwd = truncateToWidth(pwd, maxWidth: width, ellipsis: "...")
        }

        var statsParts: [String] = []
        if totals.input > 0 { statsParts.append("↑\(formatTokens(totals.input))") }
        if totals.output > 0 { statsParts.append("↓\(formatTokens(totals.output))") }
        if totals.cacheRead > 0 { statsParts.append("R\(formatTokens(totals.cacheRead))") }
        if totals.cacheWrite > 0 { statsParts.append("W\(formatTokens(totals.cacheWrite))") }
        if (totals.cacheRead > 0 || totals.cacheWrite > 0), let hitRate = stats.latestCacheHitRate {
            statsParts.append(String(format: "CH%.1f%%", hitRate))
        }
        if totals.cost > 0 {
            statsParts.append(String(format: "$%.3f", totals.cost))
        }

        let autoIndicator = autoCompactEnabled ? " (auto)" : ""
        let contextDisplay = "\(contextPercent)\(contextPercent == "?" ? "" : "%")/\(formatTokens(contextWindow))\(autoIndicator)"
        let contextText: String
        if contextPercentValue > 90 {
            contextText = theme.fg(.error, contextDisplay)
        } else if contextPercentValue > 70 {
            contextText = theme.fg(.warning, contextDisplay)
        } else {
            contextText = contextDisplay
        }
        statsParts.append(contextText)

        var statsLeft = statsParts.joined(separator: " ")
        let modelName = state.model.id
        var rightSide = modelName
        if state.model.reasoning {
            let thinking = state.thinkingLevel.rawValue
            rightSide = "\(modelName) • \(thinking == "off" ? "thinking off" : thinking)"
        }

        if let routed = session.routedModel {
            rightSide += " → \(routed.model.id)"
            if let level = routed.thinkingLevel { rightSide += " • \(level.rawValue)" }
        }

        var statsLeftWidth = visibleWidth(statsLeft)
        let rightSideWidth = visibleWidth(rightSide)

        if statsLeftWidth > width {
            statsLeft = truncateToWidth(statsLeft, maxWidth: width, ellipsis: "...")
            statsLeftWidth = visibleWidth(statsLeft)
        }

        let minPadding = 2
        let totalNeeded = statsLeftWidth + minPadding + rightSideWidth
        let statsLine: String
        if totalNeeded <= width {
            let padding = String(repeating: " ", count: width - statsLeftWidth - rightSideWidth)
            statsLine = statsLeft + padding + rightSide
        } else {
            let availableForRight = width - statsLeftWidth - minPadding
            if availableForRight > 0 {
                let plain = stripAnsi(rightSide)
                let truncated = truncateToWidth(plain, maxWidth: availableForRight, ellipsis: "")
                let padding = String(repeating: " ", count: max(0, width - statsLeftWidth - visibleWidth(truncated)))
                statsLine = statsLeft + padding + truncated
            } else {
                statsLine = statsLeft
            }
        }

        let dimStatsLeft = theme.fg(.dim, statsLeft)
        let remainder = statsLine.dropFirst(statsLeft.count)
        let dimRemainder = theme.fg(.dim, String(remainder))

        var lines = [theme.fg(.dim, pwd), dimStatsLeft + dimRemainder]

        let extensionStatuses = footerData.getExtensionStatuses()
        if !extensionStatuses.isEmpty {
            let sortedStatuses = extensionStatuses.keys.sorted().compactMap { key in
                extensionStatuses[key].map(sanitizeStatusText)
            }
            let statusLine = sortedStatuses.joined(separator: " ")
            lines.append(truncateToWidth(statusLine, maxWidth: width, ellipsis: theme.fg(.dim, "...")))
        }

        if let startDate = bashToolStartDate {
            let elapsed = Int(Date().timeIntervalSince(startDate))
            let elapsedText = theme.fg(.bashMode, "bash \(elapsed)s")
            lines.append(elapsedText)
        }

        return lines
    }
}

private func sanitizeStatusText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "[\r\n\t]", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
}
