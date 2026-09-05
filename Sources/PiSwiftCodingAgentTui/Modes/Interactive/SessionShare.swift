import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

struct SessionShareDependencies: Sendable {
    var runGH: @Sendable ([String], CancellationToken) async throws -> ExecResult
    var exportHTML: @MainActor @Sendable (AgentSession, String, String) async throws -> Void

    init(
        runGH: @escaping @Sendable ([String], CancellationToken) async throws -> ExecResult = { arguments, token in
            try await execCommand("gh", arguments, FileManager.default.currentDirectoryPath, ExecOptions(signal: token))
        },
        exportHTML: @escaping @MainActor @Sendable (AgentSession, String, String) async throws -> Void = { session, path, themeName in
            _ = try session.exportToHtml(path, themeName: themeName)
        }
    ) {
        self.runGH = runGH
        self.exportHTML = exportHTML
    }
}

@MainActor
func shareSession(
    session: AgentSession,
    tui: TUI,
    editorContainer: Container,
    editor: EditorComponentView,
    showStatus: @escaping (String) -> Void,
    showError: @escaping (String) -> Void,
    dependencies: SessionShareDependencies = SessionShareDependencies()
) async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-share-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch {
        showError("Failed to export session: \(error.localizedDescription)")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let token = CancellationToken()
    do {
        let auth = try await dependencies.runGH(["auth", "status"], token)
        guard auth.code == 0 else {
            showError(auth.code == 127
                ? "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/"
                : "GitHub CLI is not logged in. Run 'gh auth login' first.")
            return
        }
    } catch {
        showError("GitHub CLI (gh) is not installed. Install it from https://cli.github.com/")
        return
    }
    let path = directory.appendingPathComponent("session.html").path
    do {
        try await dependencies.exportHTML(session, path, theme.name)
    } catch {
        showError("Failed to export session: \(error.localizedDescription)")
        return
    }

    let loader = BorderedLoader(tui: tui, theme: theme, message: "Creating gist...")
    editorContainer.clear()
    editorContainer.addChild(loader)
    tui.setFocus(loader)
    tui.requestRender()
    var restored = false
    let restoreEditor = {
        guard !restored else { return }
        restored = true
        loader.dispose()
        editorContainer.clear()
        editorContainer.addChild(editor)
        tui.setFocus(editor)
        tui.requestRender()
    }
    loader.signal.onCancel { token.cancel() }
    loader.onAbort = {
        restoreEditor()
        showStatus("Share cancelled")
    }
    defer { restoreEditor() }
    do {
        let result = try await dependencies.runGH(["gist", "create", "--public=false", path], token)
        guard !loader.signal.isCancelled else { return }
        restoreEditor()
        guard result.code == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            showError("Failed to create gist: \(detail.isEmpty ? "Unknown error" : detail)")
            return
        }
        let gistURL = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gistID = gistURL.components(separatedBy: "/").last, !gistID.isEmpty else {
            showError("Failed to parse gist ID from gh output")
            return
        }
        let base = ProcessInfo.processInfo.environment["PI_SHARE_VIEWER_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://pi.dev/session/"
        let previewURL = base + "#" + gistID
        showStatus("Share URL: \(hyperlink(previewURL, url: previewURL))\nGist: \(hyperlink(gistURL, url: gistURL))")
    } catch {
        if !loader.signal.isCancelled {
            showError("Failed to create gist: \(error.localizedDescription)")
        }
    }
}
