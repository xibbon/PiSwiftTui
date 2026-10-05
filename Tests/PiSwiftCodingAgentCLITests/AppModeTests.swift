import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

@Suite struct AppModeTests {
    @Test func pipedStdinSelectsPrint() {
        #expect(resolveAppMode(Args(), stdinIsTTY: false, stdoutIsTTY: true) == .print)
    }

    @Test func redirectedStdoutSelectsPrint() {
        #expect(resolveAppMode(Args(), stdinIsTTY: true, stdoutIsTTY: false) == .print)
    }

    @Test func twoPipesSelectPrint() {
        #expect(resolveAppMode(Args(), stdinIsTTY: false, stdoutIsTTY: false) == .print)
    }

    @Test func twoTerminalsSelectInteractive() {
        #expect(resolveAppMode(Args(), stdinIsTTY: true, stdoutIsTTY: true) == .interactive)
    }

    @Test func shortPrintOptionSelectsPrint() throws {
        let parsed = try CLIOptions.parse(["-p"]).toArgs()
        #expect(resolveAppMode(parsed, stdinIsTTY: true, stdoutIsTTY: true) == .print)
    }

    @Test(arguments: [Mode.rpc, .json])
    func rpcAndJsonKeepTheirModes(_ mode: Mode) {
        for stdinIsTTY in [false, true] {
            for stdoutIsTTY in [false, true] {
                for print in [false, true] {
                    var parsed = Args()
                    parsed.mode = mode
                    parsed.print = print
                    let result = resolveAppMode(parsed, stdinIsTTY: stdinIsTTY, stdoutIsTTY: stdoutIsTTY)
                    #expect(result == (mode == .rpc ? .rpc : .json))
                    #expect(result.hookMode == (mode == .rpc ? .rpc : .json))
                }
            }
        }
    }

    @Test func textModeUsesTheTerminalRule() {
        var parsed = Args()
        parsed.mode = .text
        #expect(resolveAppMode(parsed, stdinIsTTY: true, stdoutIsTTY: true) == .interactive)
        #expect(resolveAppMode(parsed, stdinIsTTY: false, stdoutIsTTY: true) == .print)
        #expect(resolveAppMode(parsed, stdinIsTTY: true, stdoutIsTTY: false) == .print)
    }

    @Test func interactiveAndPrintUseTheirHookModes() {
        #expect(resolveAppMode(Args(), stdinIsTTY: true, stdoutIsTTY: true).hookMode == .tui)
        #expect(resolveAppMode(Args(), stdinIsTTY: false, stdoutIsTTY: true).hookMode == .print)
    }
}
