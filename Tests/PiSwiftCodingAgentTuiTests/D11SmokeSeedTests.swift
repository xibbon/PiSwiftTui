import Foundation
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftCodingAgentDurable

/// Opt-in fixture for the D11 pseudo-terminal checks. It does not start a model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D11_SMOKE_SEED"] == "1"),
      .timeLimit(.minutes(1)))
func seedD11SmokeSession() async throws {
    let environment = ProcessInfo.processInfo.environment
    let cwd = try #require(environment["PI_D11_SMOKE_CWD"])
    let agent = try #require(environment["PI_D11_SMOKE_AGENT"])
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
    let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
    defer { location.release() }
    let storage = try await SqliteStorage.open(path: location.database)
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
    let root = try await harness.root(context: .background)
    let ids = try await root.commit({ tx in
        var ids: [EntryID] = []
        for number in 1...300 {
            let entry = try await tx.appendEntry(root.id,
                value: .init(kind: "pi.user", model: [
                    .object(["role": "user", "content": .string("D11 smoke entry \(number)")])
                ]))
            ids.append(entry.id)
        }
        return ids
    }, context: .background)
    #expect(ids.count == 300)
    try await harness.close(context: .background)
    print("D11-SMOKE-SEEDED entries=300 directory=\(location.directory)")
}

/// Opt-in writer for the read-only pseudo-terminal check.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D11_SMOKE_WRITER"] == "1"),
      .timeLimit(.minutes(1)))
func runD11SmokeWriter() async throws {
    let environment = ProcessInfo.processInfo.environment
    let cwd = try #require(environment["PI_D11_SMOKE_CWD"])
    let agent = try #require(environment["PI_D11_SMOKE_AGENT"])
    let marker = try #require(environment["PI_D11_SMOKE_MARKER"])
    let location = try await selectSession(cwd, continueSession: true, agentDirectory: agent)
    defer { location.release() }
    let storage = try await SqliteStorage.open(path: location.database)
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
    let root = try await harness.root(context: .background)
    FileManager.default.createFile(atPath: marker + ".ready", contents: Data())
    for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker + ".write") {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(FileManager.default.fileExists(atPath: marker + ".write"))
    _ = try await root.commit({ tx in
        try await tx.appendEntry(root.id,
            value: .init(kind: "pi.user", model: [
                .object(["role": "user", "content": .string("D11 writer entry 301")])
            ]))
    }, context: .background)
    FileManager.default.createFile(atPath: marker + ".written", contents: Data())
    for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker + ".stop") {
        try await Task.sleep(for: .milliseconds(100))
    }
    try await harness.close(context: .background)
    print("D11-SMOKE-WRITER appended=301")
}
