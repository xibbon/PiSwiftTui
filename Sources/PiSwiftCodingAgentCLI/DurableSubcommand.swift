import ArgumentParser
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftCodingAgentTui

struct DurableSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "durable",
        abstract: "Start a durable coding session",
        shouldDisplay: false
    )

    @Flag(name: [.customShort("c"), .customLong("continue")], help: "Continue the previous durable session")
    var continueSession = false

    mutating func run() async throws {
        markCodingAgentEnvironment()
        time("start")
        let durable = try await openDurable(OpenDurableOptions(continueSession: continueSession))
        initializeStartupTheme(durable.settings, enableWatcher: true)
        await runDurableTui(view: durable.view, controller: durable.controller, settings: durable.settings)
        // The TUI cannot throw. Wait for close before the command returns.
        await durable.close()
    }
}
