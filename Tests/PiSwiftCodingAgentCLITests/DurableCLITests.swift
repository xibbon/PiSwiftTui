import ArgumentParser
@testable import PiSwiftCodingAgentCLI
import Testing

@Suite("Durable CLI")
struct DurableCLITests {
    @Test func startsNewSessionByDefault() throws {
        let command = try #require(PiCodingAgentCLI.parseAsRoot(["durable"]) as? DurableSubcommand)
        #expect(!command.continueSession)
    }

    @Test(arguments: ["-c", "--continue"])
    func acceptsContinueFlag(_ flag: String) throws {
        let command = try #require(PiCodingAgentCLI.parseAsRoot(["durable", flag]) as? DurableSubcommand)
        #expect(command.continueSession)
    }

    @Test func hidesCommandFromRootHelp() {
        #expect(!PiCodingAgentCLI.helpMessage().contains("durable"))
        let help = DurableSubcommand.helpMessage()
        #expect(help.contains("--continue"))
        #expect(help.contains("-c"))
    }

    @Test(arguments: ["-c", "--continue"])
    func routesLeadingContinueFlag(_ flag: String) throws {
        let arguments = PiCodingAgentCLI.preprocessArguments([flag, "durable"])
        #expect(arguments == ["durable", flag])
        let command = try #require(PiCodingAgentCLI.parseAsRoot(arguments) as? DurableSubcommand)
        #expect(command.continueSession)
    }

    @Test func routesLeadingGlobalFlagAndRejectsUnsupportedOption() {
        let arguments = PiCodingAgentCLI.preprocessArguments(["--verbose", "durable"])
        #expect(arguments == ["durable", "--verbose"])
        #expect(throws: (any Error).self) {
            try PiCodingAgentCLI.parseAsRoot(arguments)
        }
    }

    @Test func rejectsNormalSessionArguments() {
        #expect(throws: (any Error).self) {
            try PiCodingAgentCLI.parseAsRoot(["durable", "--model", "example"])
        }
        #expect(throws: (any Error).self) {
            try PiCodingAgentCLI.parseAsRoot(["durable", "hello"])
        }
    }

    @Test func respectsOptionValuesAndArgumentTerminator() throws {
        let modelArguments = ["--model", "durable", "hello"]
        #expect(PiCodingAgentCLI.preprocessArguments(modelArguments) == modelArguments)
        let session = try #require(PiCodingAgentCLI.parseAsRoot(modelArguments) as? SessionSubcommand)
        #expect(session.cli.model == "durable")
        #expect(session.cli.rawMessages == ["hello"])

        let messageArguments = ["--", "durable"]
        #expect(PiCodingAgentCLI.preprocessArguments(messageArguments) == messageArguments)
        let message = try #require(PiCodingAgentCLI.parseAsRoot(messageArguments) as? SessionSubcommand)
        #expect(message.cli.rawMessages == ["durable"])
    }
}
