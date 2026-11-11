import Darwin
import Dispatch
import Foundation
import PiSwiftCodingAgent
import Synchronization

private func pt3SignalTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment["PT3_SIGNAL_TRACE"] == "1" else { return }
    let line = String(format: "%.6f %@\n", Date().timeIntervalSince1970, message)
    line.withCString { pointer in
        _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer))
    }
}

/// The CLI owns its session. Taking it from the lock makes every exit path dispose it once.
final class SessionRunLifecycle: Sendable {
    private struct State {
        var session: AgentSession?
        var runtime: AgentSessionRuntime?
        var claimed = false
        var shutdown: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func install(_ value: AgentSession) {
        state.withLock { $0.session = value }
    }

    /// Read the published runtime session at shutdown, including after a replacement.
    func installRuntime(_ runtime: AgentSessionRuntime) {
        state.withLock { $0.runtime = runtime }
    }

    func disposeOnce() {
        let value = state.withLock { current in
            guard !current.claimed else { return nil as AgentSession? }
            current.claimed = true
            let value = current.runtime?.session ?? current.session
            current.session = nil
            current.runtime = nil
            return value
        }
        value?.dispose()
        // v1.5.2 C-TB: AgentSession.dispose() ends only its own commands. The host ends every
        // tracked shell at process shutdown, as upstream's modes do (print-mode.ts:64,
        // rpc-mode.ts:385, interactive-mode.ts:4519).
        if value != nil { killTrackedDetachedChildren() }
    }

    func shutdownAndDispose() async {
        let shutdown = state.withLock { current -> Task<Void, Never>? in
            if let shutdown = current.shutdown { return shutdown }
            guard !current.claimed, let value = current.runtime?.session ?? current.session else { return nil }
            current.claimed = true
            current.session = nil
            current.runtime = nil
            let shutdown = Task {
                pt3SignalTrace("lifecycle abort begin")
                await value.abort()
                pt3SignalTrace("lifecycle abort end; hook begin")
                if let hookRunner = value.hookRunner {
                    _ = await hookRunner.emit(SessionShutdownEvent())
                }
                pt3SignalTrace("lifecycle hook end; custom tools begin")
                await value.emitCustomToolSessionEvent(.shutdown)
                pt3SignalTrace("lifecycle custom tools end; dispose begin")
                let registry = value.modelRegistry
                value.dispose()
                pt3SignalTrace("lifecycle dispose end; credentials begin")
                // v1.5.2 b2cb62923: a refresh may already have replaced a credential.
                // Wait for its disk write before ending the process-wide shells.
                await registry.settleCredentialWrites()
                pt3SignalTrace("lifecycle credentials end; shells begin")
                killTrackedDetachedChildren()
                pt3SignalTrace("lifecycle shells end")
            }
            current.shutdown = shutdown
            return shutdown
        }
        await shutdown?.value
    }
}

func registerNonInteractiveSignalHandlers(onSignal: @escaping @Sendable () async -> Void = {}) -> [DispatchSourceSignal] {
    let signalQueue = DispatchQueue(label: "pi-coding-agent.non-interactive-signals")
    let signalCount = Mutex(0)
    let signals: [(signal: Int32, exitCode: Int32)] = [
        (SIGTERM, 143),
        (SIGHUP, 129),
    ]

    return signals.map { entry in
        signal(entry.signal, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: entry.signal, queue: signalQueue)
        source.setEventHandler {
            let deliveries = max(1, Int(source.data))
            pt3SignalTrace("signal callback signal=\(entry.signal) data=\(deliveries)")
            let count = signalCount.withLock { value in
                // A dispatch source can report several deliveries in one callback.
                value += deliveries
                return value
            }
            pt3SignalTrace("signal callback count=\(count)")
            if count == 1, let marker = ProcessInfo.processInfo.environment["PT3_FIRST_SIGNAL"] {
                try? Data("handled".utf8).write(to: URL(fileURLWithPath: marker))
            }
            if count > 1 {
                pt3SignalTrace("forced exit shells begin")
                killTrackedDetachedChildren()
                pt3SignalTrace("forced exit restore begin")
                restoreStdoutAfterMachineReadableOutput()
                pt3SignalTrace("forced exit call code=\(entry.exitCode)")
                Darwin.exit(entry.exitCode)
            }
            Task {
                pt3SignalTrace("first signal lifecycle begin")
                await onSignal()
                pt3SignalTrace("first signal lifecycle end; shells begin")
                killTrackedDetachedChildren()
                pt3SignalTrace("first signal restore begin")
                restoreStdoutAfterMachineReadableOutput()
                pt3SignalTrace("first signal exit call code=\(entry.exitCode)")
                Darwin.exit(entry.exitCode)
            }
        }
        source.resume()
        return source
    }
}

func unregisterNonInteractiveSignalHandlers(_ sources: [DispatchSourceSignal]) {
    for source in sources {
        source.cancel()
    }
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
}
