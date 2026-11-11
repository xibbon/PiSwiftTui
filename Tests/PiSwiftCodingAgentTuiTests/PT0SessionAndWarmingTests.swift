import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class PT0Terminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {}
    func stop() {}
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) {}
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor @Suite("PT0 session and warming", .serialized)
struct PT0SessionAndWarmingTests {
    private func cleanupRecorder(_ oldID: String) -> (LockedState<[String]>, @Sendable () -> Void) {
        let cleaned = LockedState<[String]>([])
        let unregister = registerSessionResourceCleanup { id in
            if id == oldID { cleaned.withLock { $0.append(oldID) } }
        }
        return (cleaned, unregister)
    }

    @Test func newCommandCleansOutgoingSession() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        let oldID = session.sessionId
        let (cleaned, unregister) = cleanupRecorder(oldID)
        defer { unregister() }
        let mode = InteractiveMode(session: session, version: "PT0")
        mode.handleNewSessionCommand()
        let deadline = ContinuousClock.now + .seconds(2)
        while session.sessionId == oldID && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.sessionId != oldID)
        #expect(cleaned.withLock { $0 } == [oldID])
        #expect(session.agent.sessionId == session.sessionId)
    }

    @Test func hookNewSessionCleansOutgoingSession() async {
        let session = t3aSession()
        defer { session.dispose() }
        let oldID = session.sessionId
        let (cleaned, unregister) = cleanupRecorder(oldID)
        defer { unregister() }
        let mode = InteractiveMode(session: session, version: "PT0")
        let setupIDs = LockedState<[String]>([])
        let result = await mode.handleHookNewSession(HookNewSessionOptions(setup: { manager in
            setupIDs.withLock { $0.append(manager.getSessionId()) }
        }))
        #expect(!result.cancelled)
        #expect(session.sessionId != oldID)
        #expect(cleaned.withLock { $0 } == [oldID])
        #expect(session.agent.sessionId == session.sessionId)
        #expect(setupIDs.withLock { $0 } == [session.sessionId])
    }

    @Test func cancelledHookNewSessionKeepsCurrentSession() async {
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([LoadedHook(path: "<pt0>", resolvedPath: "<pt0>",
            handlers: ["session_before_switch": [{ _, _ in SessionBeforeSwitchResult(cancel: true) }]],
            isExtension: true)], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        defer { session.dispose() }
        let oldID = session.sessionId
        let (cleaned, unregister) = cleanupRecorder(oldID)
        defer { unregister() }
        let mode = InteractiveMode(session: session, version: "PT0")
        let result = await mode.handleHookNewSession(nil)
        #expect(result.cancelled)
        #expect(session.sessionId == oldID)
        #expect(cleaned.withLock { $0 }.isEmpty)
        #expect(mode.chatContainer.children.isEmpty)
    }

    @Test(arguments: ["new_session", "switch_session", "fork", "clone"])
    func rpcReplacementCleansOutgoingSession(_ command: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-pt0-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.create(directory.path, directory.path)
        let session = t3aSession(manager: manager)
        defer { session.dispose() }
        let oldID = session.sessionId
        let (cleaned, unregister) = cleanupRecorder(oldID)
        defer { unregister() }
        var request: [String: Any] = [:]
        if command == "switch_session" {
            let target = SessionManager.create(directory.path, directory.path)
            target.appendMessage(.user(UserMessage(content: .text("target"))))
            request["sessionPath"] = try #require(target.getSessionFile())
        } else if command == "fork" || command == "clone" {
            let entryID = manager.appendMessage(.user(UserMessage(content: .text("fork this"))))
            if command == "fork" { request["entryId"] = entryID }
        }
        let response = try await handleRpcCommand(command, request, session, RpcOutput(write: { _ in }))
        #expect(response["success"] as? Bool == true)
        #expect(session.sessionId != oldID)
        #expect(cleaned.withLock { $0 } == [oldID])
        #expect(session.agent.sessionId == session.sessionId)
    }

    @Test func rpcCloneNeedsAnActiveLeaf() async throws {
        let session = t3aSession()
        defer { session.dispose() }
        let response = try await handleRpcCommand("clone", [:], session, RpcOutput(write: { _ in }))
        #expect(response["success"] as? Bool == false)
        #expect((response["error"] as? String)?.contains("no current entry selected") == true)
    }

    @Test func consecutiveWarmNoticesMergeAndAnotherRowBreaksTheRun() throws {
        let session = t3aSession()
        defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        let mode = InteractiveMode(session: session, version: "PT0")
        let usage = Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0,
                          totalTokens: 1, cost: UsageCost(total: 0.125))
        for _ in 0..<2 {
            _ = session.sessionManager.appendUsage("cache_warm", "test", "test", usage)
            guard case .usage(let entry) = session.sessionManager.getEntries().last else {
                Issue.record("Expected usage entry")
                return
            }
            mode.addCacheWarmingUsage(entry)
        }
        let merged = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(merged.components(separatedBy: "Cache warmed: $0.25").count == 2)
        mode.chatContainer.addChild(ThemedText({ "another row" }))
        guard case .usage(let entry) = session.sessionManager.getEntries().last else { return }
        mode.addCacheWarmingUsage(entry)
        let separate = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(separate.components(separatedBy: "Cache warmed:").count == 3)
    }

    @Test func rebuiltTranscriptMergesWarmNotices() {
        let session = t3aSession()
        defer { session.dispose() }
        session.settingsManager.setShowCacheMissNotices(true)
        let usage = Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0,
                          totalTokens: 1, cost: UsageCost(total: 0.125))
        _ = session.sessionManager.appendUsage("cache_warm", "test", "test", usage, note: "test")
        _ = session.sessionManager.appendUsage("cache_warm", "test", "test", usage, note: "test")
        let tui = TUI(terminal: PT0Terminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        let mode = InteractiveMode(session: session, tui: tui, editor: editor)
        mode.renderInitialMessages()
        let merged = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(merged.components(separatedBy: "Cache warmed (test): $0.25").count == 2)
        _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text("break"))))
        _ = session.sessionManager.appendUsage("cache_warm", "test", "test", usage, note: "test")
        mode.renderInitialMessages()
        let separate = mode.chatContainer.render(width: 120).joined(separator: "\n")
        #expect(separate.components(separatedBy: "Cache warmed (test):").count == 3)
    }
}
