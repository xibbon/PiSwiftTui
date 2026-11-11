import Darwin
import Dispatch
import Foundation
import PiSwiftCodingAgent
import Synchronization

/// The CLI owns its session. Taking it from the lock makes every exit path dispose it once.
final class SessionRunLifecycle: Sendable {
    private struct State {
        var session: AgentSession?
        var shutdown: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func install(_ value: AgentSession) {
        state.withLock { $0.session = value }
    }

    func disposeOnce() {
        let value = state.withLock { current in
            let value = current.session
            current.session = nil
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
            guard let value = current.session else { return nil }
            current.session = nil
            let shutdown = Task {
                await value.abort()
                if let hookRunner = value.hookRunner {
                    _ = await hookRunner.emit(SessionShutdownEvent())
                }
                await value.emitCustomToolSessionEvent(.shutdown)
                value.dispose()
                killTrackedDetachedChildren()
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
            let count = signalCount.withLock { value in
                value += 1
                return value
            }
            if count > 1 {
                killTrackedDetachedChildren()
                restoreStdoutAfterMachineReadableOutput()
                Darwin.exit(entry.exitCode)
            }
            Task {
                await onSignal()
                killTrackedDetachedChildren()
                restoreStdoutAfterMachineReadableOutput()
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
