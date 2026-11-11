import Foundation
import Darwin

enum ExternalEditorResult: Equatable {
    case complete(String)
    case failed(String)
}

enum ExternalEditorExit: Equatable {
    case code(Int32)
    case signal(Int32)
    case launchFailed
}

typealias ExternalEditorLauncher = (_ command: String, _ arguments: [String]) -> ExternalEditorExit

/// Keep editor process handling the same for the prompt and extension editor.
func editInExternalEditor(
    command: String,
    content: String,
    launcher: ExternalEditorLauncher = launchExternalEditor
) -> ExternalEditorResult {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-editor-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("prompt.md")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try content.write(to: file, atomically: true, encoding: .utf8)
        let parts = command.components(separatedBy: " ")
        guard let executable = parts.first, !executable.isEmpty else {
            return .failed("Failed to launch external editor: \(command)")
        }
        FileHandle.standardOutput.write(Data("Launching external editor: \(command)\nPi will resume when the editor exits.\n".utf8))
        switch launcher(executable, Array(parts.dropFirst()) + [file.path]) {
        case .launchFailed:
            return .failed("Failed to launch external editor: \(command)")
        case .signal(let signal):
            return .failed("External editor exited with \(nodeSignalName(signal)); prompt unchanged")
        case .code(let code) where code != 0:
            return .failed("External editor exited with code \(code); prompt unchanged")
        case .code:
            let edited = try String(contentsOf: file, encoding: .utf8)
            let withoutBOM = edited.hasPrefix("\u{FEFF}") ? String(edited.dropFirst()) : edited
            return .complete(withoutBOM.hasSuffix("\n") ? String(withoutBOM.dropLast()) : withoutBOM)
        }
    } catch {
        return .failed("Failed to launch external editor: \(command)")
    }
}

private func nodeSignalName(_ signal: Int32) -> String {
    switch signal {
    case SIGHUP: return "SIGHUP"
    case SIGINT: return "SIGINT"
    case SIGQUIT: return "SIGQUIT"
    case SIGILL: return "SIGILL"
    case SIGTRAP: return "SIGTRAP"
    case SIGABRT: return "SIGABRT"
    case SIGEMT: return "SIGEMT"
    case SIGFPE: return "SIGFPE"
    case SIGKILL: return "SIGKILL"
    case SIGBUS: return "SIGBUS"
    case SIGSEGV: return "SIGSEGV"
    case SIGSYS: return "SIGSYS"
    case SIGPIPE: return "SIGPIPE"
    case SIGALRM: return "SIGALRM"
    case SIGTERM: return "SIGTERM"
    case SIGURG: return "SIGURG"
    case SIGSTOP: return "SIGSTOP"
    case SIGTSTP: return "SIGTSTP"
    case SIGCONT: return "SIGCONT"
    case SIGCHLD: return "SIGCHLD"
    case SIGTTIN: return "SIGTTIN"
    case SIGTTOU: return "SIGTTOU"
    case SIGIO: return "SIGIO"
    case SIGXCPU: return "SIGXCPU"
    case SIGXFSZ: return "SIGXFSZ"
    case SIGVTALRM: return "SIGVTALRM"
    case SIGPROF: return "SIGPROF"
    case SIGWINCH: return "SIGWINCH"
    case SIGINFO: return "SIGINFO"
    case SIGUSR1: return "SIGUSR1"
    case SIGUSR2: return "SIGUSR2"
    default: return "SIG\(signal)"
    }
}

private func launchExternalEditor(_ command: String, _ arguments: [String]) -> ExternalEditorExit {
    let executable: String
    if command.contains("/") {
        executable = command
    } else {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let match = paths.map({ String($0) + "/" + command }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return .launchFailed }
        executable = match
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal
            ? .signal(process.terminationStatus) : .code(process.terminationStatus)
    } catch {
        return .launchFailed
    }
}
