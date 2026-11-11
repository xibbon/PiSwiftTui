import Darwin
import Foundation
import PiSwiftAI

@MainActor
protocol LoginTerminal: AnyObject, Sendable {
    var interactive: Bool { get }
    func write(_ line: String)
    func error(_ line: String)
    func question(_ message: String, signal: CancellationToken) async throws -> String
    func secret(_ message: String, signal: CancellationToken) async throws -> String
    func openURL(_ url: String)
}

enum LoginPromptError: Error, LocalizedError {
    case cancelled

    var errorDescription: String? { "Login cancelled" }
}

/// Read one terminal line. Read one byte at a time so a line ends on Enter and EOF cancels it.
/// Raw mode also lets this command handle Ctrl+C and keep secret input off the screen.
@MainActor
final class ProcessLoginTerminal: LoginTerminal {
    private let inputFD: Int32
    private let outputFD: Int32

    init(inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    var interactive: Bool { isatty(inputFD) == 1 && isatty(outputFD) == 1 }

    func write(_ line: String) { fputs("\(line)\n", stdout) }
    func error(_ line: String) { fputs("\(line)\n", stderr) }

    func question(_ message: String, signal: CancellationToken) async throws -> String {
        try await readLine(message, signal: signal, masked: false)
    }

    func secret(_ message: String, signal: CancellationToken) async throws -> String {
        try await readLine(message, signal: signal, masked: true)
    }

    func openURL(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func readLine(_ message: String, signal: CancellationToken, masked: Bool) async throws -> String {
        let inputFD = self.inputFD
        let outputFD = self.outputFD
        let reader = Task.detached {
            try readAuthLine(message, inputFD: inputFD, outputFD: outputFD,
                             signal: signal, masked: masked)
        }
        return try await withTaskCancellationHandler {
            try await reader.value
        } onCancel: {
            reader.cancel()
        }
    }
}

/// The poll timeout lets abort and task cancellation settle a pending prompt without stdin EOF.
func readAuthLine(
    _ message: String, inputFD: Int32, outputFD: Int32,
    signal: CancellationToken, masked: Bool
) throws -> String {
        if signal.isCancelled || Task.isCancelled { throw LoginPromptError.cancelled }
        var original = termios()
        let isTerminal = isatty(inputFD) == 1
        if isTerminal {
            guard tcgetattr(inputFD, &original) == 0 else { throw LoginPromptError.cancelled }
            var raw = original
            cfmakeraw(&raw)
            guard tcsetattr(inputFD, TCSANOW, &raw) == 0 else { throw LoginPromptError.cancelled }
        }
        defer { if isTerminal { _ = tcsetattr(inputFD, TCSANOW, &original) } }

        writeAuthBytes(message, to: outputFD)
        var bytes: [UInt8] = []
        while true {
            if signal.isCancelled || Task.isCancelled {
                writeAuthBytes("\n", to: outputFD)
                throw LoginPromptError.cancelled
            }
            var readable = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readable, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            if ready < 0 { throw LoginPromptError.cancelled }
            var byte: UInt8 = 0
            let count = Darwin.read(inputFD, &byte, 1)
            if count == 0 { writeAuthBytes("\n", to: outputFD); throw LoginPromptError.cancelled }
            if count < 0 {
                if errno == EINTR { continue }
                writeAuthBytes("\n", to: outputFD)
                throw LoginPromptError.cancelled
            }
            if byte == 3 { writeAuthBytes("\n", to: outputFD); throw LoginPromptError.cancelled }
            if byte == 10 || byte == 13 {
                writeAuthBytes("\n", to: outputFD)
                return String(decoding: bytes, as: UTF8.self)
            }
            if byte == 127 || byte == 8 {
                if !bytes.isEmpty {
                    bytes.removeLast()
                    if !masked { writeAuthBytes("\u{8} \u{8}", to: outputFD) }
                }
                continue
            }
            if byte >= 32 {
                bytes.append(byte)
                if !masked {
                    var echoed = byte
                    _ = Darwin.write(outputFD, &echoed, 1)
                }
            }
        }
}

private func writeAuthBytes(_ value: String, to fd: Int32) {
    let bytes = Array(value.utf8)
    bytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = Darwin.write(fd, base, buffer.count)
    }
}

func authWebURL(_ value: String) -> String? {
    trustedOAuthHttpURL(value)
}

func authDisplayURL(_ value: String) -> String {
    if let url = authWebURL(value) { return url }
    return String(value.unicodeScalars.map { scalar in
        if scalar.value < 32 || scalar.value == 127 { return "�" }
        return String(scalar)
    }.joined())
}
