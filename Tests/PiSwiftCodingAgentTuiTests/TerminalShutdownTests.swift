import Darwin
import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

private final class ShutdownTrace: Sendable {
    private let events = Mutex<[String]>([])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    func clear() { events.withLock { $0.removeAll() } }
    var values: [String] { events.withLock { $0 } }
}

private final class ShutdownTerminal: Terminal {
    let trace: ShutdownTrace
    private let callback = Mutex<(@Sendable (TerminalIOError) -> Void)?>(nil)
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var startError: TerminalIOError?
    var stopError: TerminalIOError?
    var handlerAtStart = false
    var restored = false
    var lost = false
    init(_ trace: ShutdownTrace) { self.trace = trace }
    var hasHandler: Bool { callback.withLock { $0 != nil } }
    func setIOErrorHandler(_ handler: (@Sendable (TerminalIOError) -> Void)?) {
        callback.withLock { $0 = handler }
    }
    func savedHandler() -> (@Sendable (TerminalIOError) -> Void)? { callback.withLock { $0 } }
    func report(_ error: TerminalIOError) {
        if error.isTerminalLoss { lost = true }
        savedHandler()?(error)
    }
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) {
        handlerAtStart = hasHandler
        trace.add("start")
        if let startError { report(startError) }
    }
    func stop() {
        trace.add("stop")
        if let stopError { report(stopError) }
        restored = !lost
    }
    func drainInput(maxMs: Int, idleMs: Int) { trace.add("drain") }
    func write(_ data: String) { if !lost { trace.add("write:\(data)") } }
    func moveBy(lines: Int) { write("move") }
    func hideCursor() { write("hide") }
    func showCursor() { write("show") }
    func clearLine() { write("clear line") }
    func clearFromCursor() { write("clear from cursor") }
    func clearScreen() { write("clear screen") }
    func setTitle(_ title: String) { write(title) }
    func setProgress(_ active: Bool) { write("progress:\(active)") }
}

@MainActor
private final class ShutdownHost {
    let directory: URL
    let trace = ShutdownTrace()
    let terminal: ShutdownTerminal
    let session: AgentSession
    let tui: TUI
    let mode: InteractiveMode
    var exits: [Int32] = []

    init(cleanup: (@Sendable () async -> Void)? = nil, startup: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        terminal = ShutdownTerminal(trace)
        let manager = SessionManager.inMemory(directory.path)
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let trace = trace
        let handler: HookHandler = { _, _ in
            trace.add("cleanup start")
            await cleanup?()
            trace.add("cleanup end")
            return nil
        }
        let runner = HookRunner([LoadedHook(path: "test", resolvedPath: "test", handlers: ["session_shutdown": [handler]], isExtension: true)], directory.path, manager, registry)
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        session = AgentSession(config: AgentSessionConfig(
            agent: Agent(AgentOptions(initialState: AgentState(systemPrompt: "", model: model, tools: []))),
            sessionManager: manager, settingsManager: .inMemory(),
            resourceLoader: DefaultResourceLoader(DefaultResourceLoaderOptions(cwd: directory.path, settingsManager: .inMemory())),
            hookRunner: runner, modelRegistry: registry
        ))
        tui = TUI(terminal: terminal)
        if startup {
            mode = InteractiveMode(session: session, version: "test", terminal: terminal)
        } else {
            let editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
            mode = InteractiveMode(session: session, tui: tui, editor: editor)
        }
        mode.crashLog = CrashLog(path: directory.appendingPathComponent("crashes.json").path)
        mode.exitProcess = { [weak self] status in self?.exits.append(status) }
        if !startup { mode.registerTerminalIOErrorHandler() }
    }

    func close() {
        session.dispose()
        try? FileManager.default.removeItem(at: directory)
    }
    var crashExists: Bool { FileManager.default.fileExists(atPath: mode.crashLog.path) }
}

private actor ShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
@Suite(.serialized) struct TerminalShutdownTests {
    @Test(arguments: [
        TerminalIOError.systemCall(operation: .read, descriptor: 0, errno: EIO),
        .endOfFile(descriptor: 0, isTerminalInput: true),
        .systemCall(operation: .write, descriptor: 1, errno: EPIPE),
        .systemCall(operation: .getAttributes, descriptor: 0, errno: ENOTTY)
    ])
    func lossExitsOnceWithoutCleanup(_ error: TerminalIOError) throws {
        let host = try ShutdownHost()
        defer { host.close() }
        let callback = try #require(host.terminal.savedHandler())
        host.terminal.report(error)
        callback(error) // An I/O queue can already have copied the removed callback.
        callback(.systemCall(operation: .read, descriptor: 0, errno: EACCES))
        #expect(host.exits == [129])
        #expect(host.trace.values.isEmpty)
        #expect(!host.terminal.restored)
        #expect(!host.terminal.hasHandler)
        #expect(!host.crashExists)
        #expect(!host.mode.chatContainer.render(width: 80).joined().contains("/bug"))
    }

    @Test func lossFromIOQueueKillsTrackedChild() async throws {
        let host = try ShutdownHost()
        defer { host.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        trackDetachedChildPid(pid)
        defer {
            untrackDetachedChildPid(pid)
            if child.isRunning { _ = kill(pid, SIGKILL) }
        }
        let callback = try #require(host.terminal.savedHandler())
        await Task.detached { callback(.systemCall(operation: .read, descriptor: 0, errno: EIO)) }.value
        for _ in 0..<100 where host.exits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<100 where child.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.exits == [129])
        #expect(!child.isRunning)
        #expect(!getTrackedDetachedChildPids().contains(pid))
        #expect(host.trace.values.isEmpty)
        #expect(!host.crashExists)
    }

    @Test func otherErrorRestoresAndRecordsOnce() throws {
        let host = try ShutdownHost()
        defer { host.close() }
        let callback = try #require(host.terminal.savedHandler())
        callback(.systemCall(operation: .read, descriptor: 0, errno: ECONNREFUSED))
        let firstTrace = host.trace.values
        callback(.systemCall(operation: .read, descriptor: 0, errno: EIO))
        #expect(host.exits == [1])
        #expect(host.trace.values == firstTrace)
        #expect(host.trace.values.contains("stop"))
        #expect(!host.trace.values.contains("cleanup start"))
        #expect(host.terminal.restored)
        #expect(!host.terminal.hasHandler)
        let records = host.mode.crashLog.read()
        #expect(records.count == 1)
        #expect(records.first?.kind == .uncaughtException)
        #expect(records.first?.message.contains("errno \(ECONNREFUSED)") == true)
    }

    @Test(arguments: [false, true])
    func normalShutdownOrderAndHandlerRemoval(_ fromSignal: Bool) async throws {
        let host = try ShutdownHost(cleanup: { await Task.yield() })
        defer { host.close() }
        host.tui.start()
        await host.tui.waitForRender()
        host.trace.clear()
        await host.mode.performShutdown(fromSignal: fromSignal)
        let events = host.trace.values
        let cleanupEnd = try #require(events.firstIndex(of: "cleanup end"))
        let firstWrite = try #require(events.firstIndex { $0.hasPrefix("write:") })
        let stop = try #require(events.firstIndex(of: "stop"))
        let drain = try #require(events.firstIndex(of: "drain"))
        if fromSignal {
            #expect(cleanupEnd < firstWrite)
            #expect(cleanupEnd < drain)
        } else {
            #expect(firstWrite < cleanupEnd)
            #expect(stop < cleanupEnd)
        }
        #expect(drain < stop)
        #expect(host.terminal.restored)
        #expect(!host.terminal.hasHandler)
        #expect(host.exits.isEmpty)
        #expect(!host.crashExists)
    }

    @Test(arguments: [false, true])
    func lossDuringCleanupStillExits(_ fromSignal: Bool) async throws {
        let gate = ShutdownGate()
        let host = try ShutdownHost(cleanup: { await gate.wait() })
        defer { host.close() }
        let shutdown = Task { await host.mode.performShutdown(fromSignal: fromSignal) }
        for _ in 0..<100 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.entered)
        let beforeLoss = host.trace.values
        host.terminal.report(.systemCall(operation: .read, descriptor: 0, errno: EIO))
        #expect(host.exits == [129])
        #expect(host.trace.values == beforeLoss)
        if fromSignal { #expect(!host.trace.values.contains("stop")) }
        #expect(!host.crashExists)
        await gate.release()
        await shutdown.value
        #expect(host.trace.values.filter { $0 != "cleanup end" } == beforeLoss)
        #expect(host.exits == [129])
    }

    @Test func restoreLossTakesEmergencyPath() async throws {
        let host = try ShutdownHost()
        defer { host.close() }
        host.terminal.stopError = .systemCall(operation: .setAttributes, descriptor: 0, errno: EIO)
        await host.mode.performShutdown(fromSignal: true)
        #expect(host.exits == [129])
        #expect(!host.crashExists)
        #expect(!host.terminal.restored)
        #expect(!host.terminal.hasHandler)
    }

    @Test func handlerIsInstalledBeforeTerminalStarts() async throws {
        let host = try ShutdownHost(startup: true)
        defer { host.close() }
        host.terminal.startError = .systemCall(operation: .getAttributes, descriptor: 0, errno: ENOTTY)
        await host.mode.start()
        #expect(host.terminal.handlerAtStart)
        #expect(host.exits == [129])
        #expect(!host.terminal.hasHandler)
        #expect(!host.trace.values.contains("stop"))
        #expect(!host.trace.values.contains("cleanup start"))
        #expect(!host.crashExists)
        #expect(fcntl(STDERR_FILENO, F_GETNOSIGPIPE) == 1)
    }
}
