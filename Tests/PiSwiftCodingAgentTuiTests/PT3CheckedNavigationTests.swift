import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

private final class PT3Terminal: Terminal {
    var columns = 100
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

private actor PT3Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Suite("PT3 checked navigation", .serialized)
struct PT3CheckedNavigationTests {
    private func host() -> (AgentSession, HookRunner, InteractiveMode) {
        let manager = SessionManager.inMemory("/tmp")
        let auth = AuthStorage.inMemory()
        auth.setRuntimeApiKey("test", "test-key")
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let runner = HookRunner([], "/tmp", manager, registry)
        let session = t3aSession(manager: manager, registry: registry, runner: runner)
        let tui = TUI(terminal: PT3Terminal())
        let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        return (session, runner, InteractiveMode(session: session, tui: tui, editor: editor))
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // v1.5.2 c3b938e3e, suite/regressions/9221-reload-during-tool.test.ts.
    @Test("reload and tree navigation report an active response")
    func responseGuardsReachTheTranscript() async throws {
        let (session, runner, mode) = host()
        defer { session.dispose() }
        await mode.initializeHooksAndCustomTools()
        session.agent.streamFn = { model, _, options in
            let stream = AssistantMessageEventStream()
            Task {
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                stream.push(.error(reason: .aborted, error: AssistantMessage(
                    content: [], api: model.api, provider: model.provider, model: model.id,
                    usage: t3aUsage(), stopReason: .aborted)))
            }
            return stream
        }
        let running = Task { try? await session.prompt("running") }
        #expect(await waitUntil { session.isStreaming })
        await mode.handleReloadCommand()
        let result = await runner.createCommandContext().navigateTree("unknown", nil)
        #expect(result.cancelled)
        let transcript = mode.chatContainer.render(width: 180).joined(separator: "\n")
        #expect(transcript.contains("Wait for the current response to finish before reloading."))
        #expect(transcript.contains("Wait for the current response to finish before navigating the session tree."))
        await session.abort()
        await running.value
    }

    // v1.5.2 c3b938e3e and 8a3e163b0, agent-session.ts:2182,3817,4135.
    @Test("reload, tree navigation, and prompt report compaction")
    func compactionGuardsReachTheTranscript() async {
        let (session, runner, mode) = host()
        defer { session.dispose() }
        await mode.initializeHooksAndCustomTools()
        let gate = PT3Gate()
        let started = LockedState(false)
        let compactBlock: @Sendable () async throws -> CompactionResult? = {
            started.withLock { $0 = true }
            await gate.wait()
            return nil
        }
        let compacting = Task {
            await session.runAutoCompaction(reason: .threshold, willRetry: false, compactBlock: compactBlock)
        }
        #expect(await waitUntil { started.withLock { $0 } })
        await mode.handleReloadCommand()
        let result = await runner.createCommandContext().navigateTree("unknown", nil)
        #expect(result.cancelled)
        await mode.prompt("overlap", images: nil)
        let transcript = mode.chatContainer.render(width: 180).joined(separator: "\n")
        #expect(transcript.contains("Wait for compaction to finish before reloading."))
        #expect(transcript.contains("Wait for the current compaction or tree navigation to finish before navigating the session tree."))
        #expect(transcript.contains("Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry."))
        await gate.release()
        await compacting.value
    }
}
