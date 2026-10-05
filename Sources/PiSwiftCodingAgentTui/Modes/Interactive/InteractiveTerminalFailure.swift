import Foundation
import MiniTui

/// Keep the operation and saved errno in the crash record and diagnostic.
struct InteractiveTerminalFailure: LocalizedError {
    let error: TerminalIOError

    var errorDescription: String? {
        if let code = error.errno {
            return "Terminal \(error.operation) failed on descriptor \(error.descriptor) (errno \(code))."
        }
        return "Terminal input ended on descriptor \(error.descriptor)."
    }
}
