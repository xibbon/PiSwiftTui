import Foundation
import MiniTui
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftCodingAgentDurable
@testable import PiSwiftCodingAgentTui

/// Opt-in: PI_D11_SCALE=1 swift test --filter d11HundredThousandSQLiteTranscript.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D11_SCALE"] == "1"),
      .timeLimit(.minutes(10)))
func d11HundredThousandSQLiteTranscript() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("piswift-d11-scale-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let cwd = base.appendingPathComponent("project").path
    let agent = base.appendingPathComponent("agent").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
    let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
    let storage = try await SqliteStorage.open(path: location.database)
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
    let root = try await harness.root(context: .background)
    for start in stride(from: 0, to: 100_000, by: 1_000) {
        try await root.commit({ tx in
            for index in start..<(start + 1_000) {
                _ = try await tx.appendEntry(root.id, value: .init(kind: "benchmark.line",
                    data: .string("Entry \(index + 1)")))
            }
        }, context: .background)
    }
    try await harness.close(context: .background)
    location.release()
    let dependencies = OpenDurableDependencies(agentDirectory: agent, makeModels: { _ in
        DurableRuntimeModels(models: FakeDurableModels(), available: [],
            initial: { _ in .init(model: nil, thinkingLevel: nil) })
    })
    let clock = ContinuousClock()
    let start = clock.now
    let opened = try await openDurable(.init(cwd: cwd, continueSession: true,
        transcriptMode: .paged), dependencies: dependencies)
    let elapsed = start.duration(to: clock.now)
    let milliseconds = Double(elapsed.components.seconds) * 1_000 +
        Double(elapsed.components.attoseconds) / 1e15
    try await renderD11Scale(opened: opened, cwd: cwd)
    print("D11-SCALE sqlite_entries=100000 paged_open_ms=\(String(format: "%.3f", milliseconds)) rows=51,101,151,201")
    await opened.close()
}

@MainActor
private func renderD11Scale(opened: OpenDurableResult, cwd: String) async throws {
    let tui = DurableTui(cwd: cwd, handlers: DurableTuiHandlers(
        submit: { _ in }, followUp: { _ in }, abort: {}, exit: {}, selectModel: {}, cycleThinking: {}
    ), terminal: ToolTestTerminal())
    defer { tui.stop() }
    for step in 0...3 {
        let snapshot = opened.hostView.hostCurrent()
        tui.apply(snapshot)
        let count = 51 + step * 50
        #expect(snapshot.rows.count == count)
        #expect(tui.chat.children.count == count + 1)
        #expect(tui.rowConstructionCount == count)
        if step < 3 { await opened.hostController.loadEarlier() }
    }
}
