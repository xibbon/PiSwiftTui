import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
private final class StatusFixture {
    var reports: [ProgramStatus] = []
    var name: String?
    lazy var reporter = ProgramStatusReporter(send: { [unowned self] in reports.append($0) }, getSessionName: { [unowned self] in name })
    init(_ name: String? = nil) { self.name = name }
    func send(_ inputs: ProgramStatusInput...) { inputs.forEach(reporter.handleEvent) }
    var last: ProgramStatus? { reports.last }
    func expect(_ state: ProgramStatus.State, message: String? = nil, kind: ProgramStatus.Kind? = nil) {
        #expect(last == ProgramStatus(state: state, app: APP_NAME, kind: kind, message: message))
    }
}

@MainActor @Suite struct ProgramStatusReporterTests {
    @Test func idleWorkingAndDone() {
        let f = StatusFixture("Fix login")
        f.reporter.report(); f.expect(.idle)
        f.send(.agentStart); f.expect(.working, message: "Fix login")
        f.send(.assistantEnd(isError: false, errorMessage: nil)); f.expect(.working, message: "Fix login")
        f.send(.agentSettled(aborted: false)); f.expect(.done, message: "Fix login")
    }
    @Test func retriesFinalErrorsAndAborts() {
        let f = StatusFixture()
        f.send(.agentStart, .assistantEnd(isError: true, errorMessage: "overloaded"), .assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: false)); f.expect(.done)
        f.send(.agentStart, .assistantEnd(isError: true, errorMessage: "Invalid API key\n{details}"), .agentSettled(aborted: false)); f.expect(.error, message: "Invalid API key")
        f.send(.agentStart, .assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: true)); f.expect(.idle)
    }
    @Test func recoveryCompactionErrorsAndLaterSuccess() {
        let f = StatusFixture()
        f.send(.agentStart, .compactionStart, .compactionEnd(manual: false, aborted: false, errorMessage: "Compaction failed\nstack"), .agentSettled(aborted: false)); f.expect(.error, message: "Compaction failed")
        f.send(.agentStart, .compactionStart, .compactionEnd(manual: false, aborted: false, errorMessage: "Compaction failed"), .assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: false)); f.expect(.done)
    }
    @Test func runAndManualCompaction() {
        let f = StatusFixture("Session")
        f.send(.agentStart, .compactionStart); f.expect(.working, message: "Compacting context")
        f.send(.compactionEnd(manual: false, aborted: false, errorMessage: nil)); f.expect(.working, message: "Session")
        f.send(.assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: false))
        f.send(.compactionStart, .compactionEnd(manual: true, aborted: false, errorMessage: nil)); f.expect(.done, message: "Session")
        f.send(.compactionStart, .compactionEnd(manual: true, aborted: false, errorMessage: "No model")); f.expect(.error, message: "No model")
        f.send(.compactionStart, .compactionEnd(manual: true, aborted: true, errorMessage: nil)); f.expect(.idle)
    }
    @Test func latestDialogAndUnderlyingState() {
        let f = StatusFixture()
        f.send(.agentStart)
        f.reporter.setBlocked(source: "extension-selector", status: BlockedStatus(kind: .permission, message: "Allow bash?"))
        f.reporter.setBlocked(source: "login", status: BlockedStatus(kind: .auth, message: "Log in to Anthropic"))
        f.expect(.blocked, message: "Log in to Anthropic", kind: .auth)
        f.reporter.setBlocked(source: "login", status: nil)
        f.send(.assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: false))
        f.expect(.blocked, message: "Allow bash?", kind: .permission)
        f.reporter.setBlocked(source: "extension-selector", status: BlockedStatus(kind: .question, message: "Pick one"))
        f.expect(.blocked, message: "Pick one", kind: .question)
        f.reporter.setBlocked(source: "extension-selector", status: nil); f.expect(.done)
    }
    @Test func deduplicationAndNameChanges() {
        let f = StatusFixture("Old")
        f.send(.agentStart, .ignored, .assistantEnd(isError: false, errorMessage: nil)); f.reporter.report()
        #expect(f.reports.count == 1)
        f.name = "New"; f.send(.sessionInfoChanged); f.expect(.working, message: "New")
    }
    @Test func replacedSessionReturnsToIdle() {
        let f = StatusFixture()
        f.send(.agentStart, .assistantEnd(isError: false, errorMessage: nil), .agentSettled(aborted: false))
        f.reporter.reset(); f.expect(.idle)
    }
    @Test func emptyErrorsAndCRLF() {
        let f = StatusFixture()
        for text in [nil, "", " \r\nprivate", "\u{FEFF}"] as [String?] {
            f.send(.agentStart, .assistantEnd(isError: true, errorMessage: text), .agentSettled(aborted: false)); f.expect(.error, message: "Error")
        }
        f.send(.agentStart, .assistantEnd(isError: true, errorMessage: " Failed \r\nprivate"), .agentSettled(aborted: false)); f.expect(.error, message: "Failed")
        f.send(.agentStart, .assistantEnd(isError: true, errorMessage: "\u{FEFF}Failed\u{FEFF}\nprivate"), .agentSettled(aborted: false)); f.expect(.error, message: "Failed")
        f.send(.agentStart, .assistantEnd(isError: true, errorMessage: "\u{0085}Failed\u{0085}\nprivate"), .agentSettled(aborted: false)); f.expect(.error, message: "\u{0085}Failed\u{0085}")
    }
    @Test func resetKeepsDialogAndClearsCompaction() {
        let f = StatusFixture()
        f.send(.compactionStart)
        f.reporter.setBlocked(source: "dialog", status: BlockedStatus(kind: .question, message: "Choose"))
        f.reporter.reset(); f.expect(.blocked, message: "Choose", kind: .question)
        f.reporter.setBlocked(source: "dialog", status: nil); f.expect(.idle)
    }
    @Test func sessionEventAdapterDoesNotReportAssistantText() {
        let f = StatusFixture()
        f.reporter.handleEvent(AgentSessionEvent.agent(.agentStart))
        var message = t3aAssistant()
        message.content = [.text(TextContent(text: "secret assistant output"))]
        f.reporter.handleEvent(AgentSessionEvent.agent(.messageEnd(message: .assistant(message))))
        f.reporter.handleEvent(AgentSessionEvent.agent(.turnStart))
        #expect(f.reports.count == 1)
        f.reporter.handleEvent(AgentSessionEvent.autoCompactionStart(reason: .overflow)); f.expect(.working, message: "Compacting context")
        f.reporter.handleEvent(AgentSessionEvent.autoCompactionEnd(result: nil, aborted: false, willRetry: false, errorMessage: "Failed\nsecret"))
        f.reporter.handleEvent(AgentSessionEvent.agentSettled(aborted: false)); f.expect(.error, message: "Failed")
        #expect(!f.reports.contains { $0.message?.contains("secret") == true })
    }
}
