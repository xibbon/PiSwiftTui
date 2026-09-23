import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private let bugReportDisclaimer = "This report is for the Pi developers. It includes the Pi version, operating system, model and provider configuration without API keys, loaded extensions, settings, and provider error diagnostics from this session."
private let bugReportTranscriptNote = "The transcript contains your messages, model output, tool calls and results, including file contents and command output read during this session."

enum BugReportFlowError: Error, LocalizedError {
    case summaryFailed(String)
    var errorDescription: String? {
        switch self { case .summaryFailed(let message): return message }
    }
}

@MainActor
struct BugReportUI {
    let session: AgentSession
    let tui: TUI
    let editorContainer: Container
    let editor: EditorComponentView
    let showStatus: (String) -> Void
    let showError: (String) -> Void
    var exportDirectory: String = FileManager.default.currentDirectoryPath
    var crashLog: CrashLog = CrashLog()

    func run(initialHint: String?) async {
        guard let description = await askDescription(initialHint: initialHint) else { return cancel() }
        guard let transcriptChoice = await choose("Include the session transcript?", ["Yes, include the transcript", "No"], description: bugReportTranscriptNote) else { return cancel() }
        let includeSession = transcriptChoice != "No"
        var includeSummary = false
        if !includeSession {
            let model = session.agent.state.model.name
            let notice = "The transcript is sent to \(session.agent.state.model.provider) with your credentials and tokens. Only the generated summary is attached; the transcript stays on your machine."
            guard let summaryChoice = await choose("Attach a summary written by \(model) instead?", ["Yes, generate a summary", "No"], description: notice) else { return cancel() }
            includeSummary = summaryChoice != "No"
        }
        let hint = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = "Description: \(hint.isEmpty ? "none" : hint)\nTranscript: \(includeSession ? "included" : "not included")\nSummary: \(includeSummary ? "written by \(session.agent.state.model.name)" : "none")\n\nExport writes a ZIP archive to the current directory."
        guard await choose("Bug report", ["Export as Zip", "Cancel"], description: detail) == "Export as Zip" else { return cancel() }

        var summary: String?
        if includeSummary {
            do {
                summary = try await writeSummary(hint: hint.isEmpty ? nil : hint)
            } catch {
                if error is CancellationError { return cancel() }
                showError("Failed to write bug report summary: \(error.localizedDescription)")
                return
            }
        }

        let crashes = crashLog.read()
        let metadata = bugReportMetadata(session: session, hint: hint.isEmpty ? nil : hint, includeSession: includeSession, includeSummary: summary != nil)
        do {
            let bundle = try makeBugReportBundle(
                metadata: metadata, session: session.sessionManager, crashes: crashes,
                includeSession: includeSession, summary: summary,
                createTrailingEntries: { parentId, timestamp in
                    createShareTrailingEntries(session: session, parentId: parentId, timestamp: timestamp)
                }
            )
            guard let id = metadata["id"]?.value as? String else {
                showError("Failed to build bug report: missing report ID")
                return
            }
            let path = URL(fileURLWithPath: exportDirectory)
                .appendingPathComponent(bugReportArchiveFileName(id: id)).path
            try writeBugReportArchive(bundle, to: path)
            appendBugReportSessionEntry(session.sessionManager, id: id, hint: hint.isEmpty ? nil : hint,
                                        includeSession: includeSession, includeSummary: summary != nil, path: path)
            if !crashes.isEmpty { crashLog.clear() }
            showStatus("Bug report exported to: \(path)\nReport ID: \(id)")
        } catch {
            showError("Failed to write bug report: \(error.localizedDescription)")
        }
    }

    private func cancel() { showStatus("Bug report cancelled") }

    private func askDescription(initialHint: String?) async -> String? {
        await withCheckedContinuation { continuation in
            let component = HookEditorComponent(tui: tui, title: "Report a bug", prefill: initialHint,
                description: "\(bugReportDisclaimer)\n\nWhat went wrong? (optional)",
                onSubmit: { value in restoreEditor(); continuation.resume(returning: value) },
                onCancel: { restoreEditor(); continuation.resume(returning: nil) })
            show(component)
        }
    }

    private func choose(_ title: String, _ options: [String], description: String) async -> String? {
        await withCheckedContinuation { continuation in
            let component = HookSelectorComponent(title: title, options: options, description: description,
                onSelect: { value in restoreEditor(); continuation.resume(returning: value) },
                onCancel: { restoreEditor(); continuation.resume(returning: nil) })
            show(component)
        }
    }

    private func writeSummary(hint: String?) async throws -> String {
        let token = CancellationToken()
        let model = session.agent.state.model
        let loader = BorderedLoader(tui: tui, theme: theme, message: "Writing summary with \(model.name)...")
        loader.onAbort = { token.cancel() }
        show(loader)
        defer { loader.dispose(); restoreEditor() }
        let conversation = bugReportSummaryConversation(session.messages, contextWindow: model.contextWindow)
        let instructions = "Write a concise Markdown bug report for the Pi developers with these sections: What the user was doing, What went wrong, Steps to reproduce, Relevant details. Quote errors when present. Do not include file contents, secrets, or credentials. Refer to files by path. Do not continue the conversation."
        let prompt = "<conversation>\n\(conversation)\n</conversation>\n\n\(hint.map { "<user-report>\n\($0)\n</user-report>\n\n" } ?? "")\(instructions)"
        let context = Context(systemPrompt: "Write a factual bug report about this session for the Pi developers. Output only the report.", messages: [.user(UserMessage(content: .text(prompt)))])
        let response = await session.modelRegistry.streamSimple(model: model, context: context,
            options: SimpleStreamOptions(maxTokens: min(4096, model.maxTokens), signal: token,
                                         reasoning: model.reasoning ? PiSwiftAI.ThinkingLevel(rawValue: session.agent.state.thinkingLevel.rawValue) : nil,
                                         sessionId: session.sessionId)).result()
        if token.isCancelled { throw CancellationError() }
        guard response.stopReason != .aborted, response.stopReason != .error else {
            throw BugReportFlowError.summaryFailed(response.errorMessage ?? "The model could not write the summary")
        }
        guard !response.content.contains(where: { if case .toolCall = $0 { true } else { false } }) else {
            throw BugReportFlowError.summaryFailed("The model attempted to call a tool")
        }
        let text = response.content.compactMap { block -> String? in
            if case .text(let content) = block { return content.text }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BugReportFlowError.summaryFailed("The model returned an empty summary") }
        return text
    }

    private func show(_ component: Component) {
        editorContainer.clear()
        editorContainer.addChild(component)
        tui.setFocus(component)
        tui.requestRender()
    }

    private func restoreEditor() {
        editorContainer.clear()
        editorContainer.addChild(editor)
        tui.setFocus(editor)
        tui.requestRender()
    }
}

func bugReportSummaryConversation(_ messages: [AgentMessage], contextWindow: Int) -> String {
    let budget = Int(Double(contextWindow > 0 ? contextWindow : 128_000) * 0.6)
    var selected: [AgentMessage] = []
    var estimatedTokens = 0
    for message in messages.reversed() {
        let rendered = serializeConversation(convertToLlm([message]))
        let next = max(1, (rendered.utf16.count + 3) / 4)
        if !selected.isEmpty && estimatedTokens + next > budget { break }
        selected.append(message)
        estimatedTokens += next
    }
    let conversation = serializeConversation(convertToLlm(Array(selected.reversed())))
    if selected.count < messages.count {
        return "Only the last \(selected.count) of \(messages.count) messages are shown.\n\n\(conversation)"
    }
    return conversation
}

func bugReportMetadata(session: AgentSession, hint: String?, includeSession: Bool, includeSummary: Bool) -> [String: AnyCodable] {
    let extensions = session.resourceLoader.getExtensions()
    let settings = session.settingsManager
    let model = session.agent.state.model
    let input = BugReportMetadataInput(
        hint: hint, sessionId: session.sessionId, cwd: session.sessionManager.getCwd(),
        includeSession: includeSession, includeSummary: includeSummary, messageCount: session.messages.count,
        model: model,
        provider: ["id": AnyCodable(model.provider),
                   "authConfigured": AnyCodable(session.modelRegistry.hasConfiguredAuth(model))],
        thinkingLevel: session.agent.state.thinkingLevel.rawValue,
        extensions: extensions.paths.map { BugReportExtension(path: $0, source: $0, scope: "unknown", origin: "resource") },
        extensionErrors: extensions.diagnostics.map { ["message": $0.message, "path": $0.path ?? ""] },
        globalSettings: settings.settingsJSONForDiagnostics(settings.getGlobalSettings()),
        projectSettings: settings.settingsJSONForDiagnostics(settings.getProjectSettings())
    )
    return collectBugReportMetadata(input)
}
