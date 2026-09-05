import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private final class CatalogOperation {
    var calls = 0
    var signal: CancellationToken?
    var continuation: CheckedContinuation<ModelsRefreshResult, Never>?
    func run(_ signal: CancellationToken) async -> ModelsRefreshResult {
        calls += 1
        self.signal = signal
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: ModelsRefreshResult(aborted: signal?.isCancelled ?? false))
        continuation = nil
    }
}

@MainActor
@Suite struct CatalogCoordinatorV085Tests {
    @Test func sharesOneRuntimeOperation() async {
        let coordinator = InteractiveCatalogRefreshCoordinator()
        let runtime = CatalogOperation()
        let first = Task { await coordinator.refresh(runtime: runtime, signal: CancellationToken(), operation: runtime.run) }
        let second = Task { await coordinator.refresh(runtime: runtime, signal: CancellationToken(), operation: runtime.run) }
        for _ in 0..<100 where runtime.calls == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        #expect(runtime.calls == 1)
        runtime.finish()
        #expect(!(await first.value).aborted)
        #expect(!(await second.value).aborted)
    }

    @Test func cancelledWaiterDoesNotCancelSharedRefresh() async {
        let coordinator = InteractiveCatalogRefreshCoordinator()
        let runtime = CatalogOperation()
        let firstSignal = CancellationToken()
        let first = Task { await coordinator.refresh(runtime: runtime, signal: firstSignal, operation: runtime.run) }
        let second = Task { await coordinator.refresh(runtime: runtime, signal: CancellationToken(), operation: runtime.run) }
        for _ in 0..<100 where runtime.calls == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        firstSignal.cancel()
        #expect((await first.value).aborted)
        #expect(runtime.signal?.isCancelled == false)
        runtime.finish()
        #expect(!(await second.value).aborted)
    }

    @Test func lastWaiterCancelsOperationAndNextCallerStartsFresh() async {
        let coordinator = InteractiveCatalogRefreshCoordinator()
        let runtime = CatalogOperation()
        let first = Task { await coordinator.refresh(runtime: runtime, signal: CancellationToken(), operation: runtime.run) }
        for _ in 0..<100 where runtime.calls == 0 { await Task.yield() }
        first.cancel()
        #expect((await first.value).aborted)
        #expect(runtime.signal?.isCancelled == true)
        runtime.finish()
        let second = Task { await coordinator.refresh(runtime: runtime, signal: CancellationToken(), operation: runtime.run) }
        for _ in 0..<100 where runtime.calls < 2 { await Task.yield() }
        #expect(runtime.calls == 2)
        runtime.finish()
        #expect(!(await second.value).aborted)
    }

    @Test func cancelledCallerDoesNotStartAnOperation() async {
        let coordinator = InteractiveCatalogRefreshCoordinator()
        let runtime = CatalogOperation()
        let signal = CancellationToken(); signal.cancel()
        let result = await coordinator.refresh(runtime: runtime, signal: signal, operation: runtime.run)
        #expect(result.aborted)
        #expect(runtime.calls == 0)
    }
}
