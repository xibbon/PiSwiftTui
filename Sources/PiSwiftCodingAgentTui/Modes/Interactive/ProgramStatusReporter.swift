import Foundation
import MiniTui
import PiSwiftCodingAgent

struct BlockedStatus {
    var kind: ProgramStatus.Kind
    var message: String
}

enum ProgramStatusInput {
    case agentStart
    case assistantEnd(isError: Bool, errorMessage: String?)
    case compactionStart
    case compactionEnd(manual: Bool, aborted: Bool, errorMessage: String?)
    case agentSettled(aborted: Bool)
    case sessionInfoChanged
    case ignored
}

@MainActor
final class ProgramStatusReporter {
    private let send: (ProgramStatus) -> Void
    private let getSessionName: () -> String?
    private var runActive = false
    private var compacting = false
    private var runResult = ProgramStatus(state: .done)
    private var restingStatus = ProgramStatus(state: .idle)
    private var blocked: [(source: String, status: BlockedStatus)] = []
    private var lastReport: ProgramStatus?

    init(send: @escaping (ProgramStatus) -> Void, getSessionName: @escaping () -> String?) {
        self.send = send
        self.getSessionName = getSessionName
    }

    func handleEvent(_ event: AgentSessionEvent) {
        let input: ProgramStatusInput
        switch event {
        case .agent(.agentStart): input = .agentStart
        case .agent(.messageEnd(let message)):
            guard case .assistant(let assistant) = message else { return }
            input = .assistantEnd(isError: assistant.stopReason == .error, errorMessage: assistant.errorMessage)
        case .autoCompactionStart: input = .compactionStart
        case .autoCompactionEnd(_, let aborted, _, let errorMessage):
            input = .compactionEnd(manual: false, aborted: aborted, errorMessage: errorMessage)
        case .agentSettled(let aborted): input = .agentSettled(aborted: aborted)
        default: input = .ignored
        }
        handleEvent(input)
    }

    func handleEvent(_ input: ProgramStatusInput) {
        switch input {
        case .agentStart:
            runActive = true
            runResult = ProgramStatus(state: .done)
        case .assistantEnd(let isError, let errorMessage):
            runResult = isError ? errorStatus(errorMessage) : ProgramStatus(state: .done)
        case .compactionStart: compacting = true
        case .compactionEnd(let manual, let aborted, let errorMessage):
            compacting = false
            if runActive {
                if aborted { runResult = ProgramStatus(state: .idle) }
                else if let errorMessage, !errorMessage.isEmpty { runResult = errorStatus(errorMessage) }
            } else if aborted {
                restingStatus = ProgramStatus(state: .idle)
            } else if manual {
                restingStatus = errorMessage.map { $0.isEmpty ? ProgramStatus(state: .done) : errorStatus($0) } ?? ProgramStatus(state: .done)
            }
        case .agentSettled(let aborted):
            runActive = false
            restingStatus = aborted ? ProgramStatus(state: .idle) : runResult
        case .sessionInfoChanged: break
        case .ignored: return
        }
        report()
    }

    func setBlocked(source: String, status: BlockedStatus?) {
        blocked.removeAll { $0.source == source }
        if let status { blocked.append((source, status)) }
        report()
    }

    func reset() {
        runActive = false
        compacting = false
        runResult = ProgramStatus(state: .done)
        restingStatus = ProgramStatus(state: .idle)
        report()
    }

    func report() {
        var status: ProgramStatus
        if let dialog = blocked.last?.status {
            status = ProgramStatus(state: .blocked, kind: dialog.kind, message: dialog.message)
        } else if compacting {
            status = ProgramStatus(state: .working, message: "Compacting context")
        } else {
            status = runActive ? ProgramStatus(state: .working) : restingStatus
            if status.state == .working || status.state == .done { status.message = getSessionName() }
        }
        status.app = APP_NAME
        guard status != lastReport else { return }
        lastReport = status
        send(status)
    }

    private func errorStatus(_ text: String?) -> ProgramStatus {
        // Match JavaScript String.trim(), including BOM and excluding NEL.
        let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D} \u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        let line = text?.components(separatedBy: "\n").first?.trimmingCharacters(in: whitespace)
        return ProgramStatus(state: .error, message: line.flatMap { $0.isEmpty ? nil : $0 } ?? "Error")
    }
}
