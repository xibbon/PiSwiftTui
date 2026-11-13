import ArgumentParser
import Foundation
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftCodingAgentTui
import PiSwiftDurable

struct DurableSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "durable",
        abstract: "Start a durable coding session",
        shouldDisplay: false
    )

    @Flag(name: [.customShort("c"), .customLong("continue")], help: "Continue the previous durable session")
    var continueSession = false

    @Flag(name: .long, help: "Open the previous durable session as a read-only snapshot. Use /refresh to update it")
    var readOnly = false

    static func checkTerminalResult(_ result: SessionCloseResult,
                                    report: (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }) throws {
        if case .failed(let error) = result {
            let cause = (error as? SessionFailed)?.cause ?? error
            report((cause as? any LocalizedError)?.errorDescription ?? String(describing: cause))
            throw ExitCode.failure
        }
    }

    mutating func run() async throws {
        markCodingAgentEnvironment()
        time("start")
        let durable: OpenDurableResult
        do {
            durable = try await openDurablePaged(continueSession: continueSession || readOnly,
                                                 mode: readOnly ? .readOnly : .write)
        } catch SessionLocationError.alreadyOpen(let directory, let cause)
                    where cause.code == .EWOULDBLOCK {
            // Open the session that holds the lock, even if a newer session now exists.
            durable = try await openDurable(.init(continueSession: true, mode: .readOnly,
                                                  transcriptMode: .paged,
                                                  sessionID: URL(fileURLWithPath: directory).lastPathComponent))
        }
        initializeStartupTheme(durable.settings, enableWatcher: true)
        try Self.checkTerminalResult(await runDurableTui(durable))
    }
}
