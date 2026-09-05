import Foundation
import Synchronization
import Testing
@testable import PiSwiftCodingAgentTui

@Suite struct RpcPendingCompactionTests {
    @Test func finishedCompactionTasksLeaveTheSet() async {
        let pending = PendingCompactionTasks()
        let gate = AsyncStream<Void>.makeStream()
        pending.run { for await _ in gate.stream { break } }
        pending.run { }
        #expect(pending.count >= 1)
        gate.continuation.yield(())
        gate.continuation.finish()
        await pending.waitForAll()
        // Self-removal runs after the awaited body. Give it one hop.
        for _ in 0..<50 where pending.count > 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(pending.count == 0)
    }

    @Test func waitForAllJoinsRunningTasks() async {
        let pending = PendingCompactionTasks()
        let done = Mutex(false)
        pending.run {
            try? await Task.sleep(for: .milliseconds(20))
            done.withLock { $0 = true }
        }
        await pending.waitForAll()
        #expect(done.withLock { $0 })
    }
}
