import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct TerminalLossResult: Decodable {
    let drewFrame: Bool
    let outputBytes: Int
    let exitStatus: Int?
    let elapsedSeconds: Double
}

private enum TerminalLossTestError: Error {
    case harnessTimedOut
    case cleanupTimedOut
}

// setsid() with an already open slave does not give the child a controlling terminal.
// Thus, closing the master tests input loss without a kernel SIGHUP to the child.
private let terminalLossHarness = #"""
import fcntl
import json
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time

def stop_harness(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, stop_harness)
master = None
slave = None
child = None
try:
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    env = dict(os.environ, PI_CODING_AGENT_DIR=sys.argv[2], TERM="xterm-256color")
    child = subprocess.Popen(
        [sys.argv[1]], stdin=slave, stdout=slave, stderr=slave,
        env=env, cwd=sys.argv[2], start_new_session=True,
    )
    os.close(slave)
    slave = None
    os.set_blocking(master, False)
    output = bytearray()
    startup_deadline = time.monotonic() + 8
    # Both terminal renderers finish a frame with this sequence.
    frame_end = b"\x1b[?2026l"
    while time.monotonic() < startup_deadline:
        if select.select([master], [], [], 0.05)[0]:
            try:
                chunk = os.read(master, 65536)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
            if frame_end in output:
                break
        if child.poll() is not None:
            break
    drew_frame = frame_end in output and child.poll() is None
    os.close(master)
    master = None
    loss_time = time.monotonic()
    try:
        exit_status = child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        exit_status = None
    elapsed = time.monotonic() - loss_time
    print(json.dumps(dict(
        drewFrame=drew_frame, outputBytes=len(output),
        exitStatus=exit_status, elapsedSeconds=elapsed,
    )), flush=True)
finally:
    for fd in (master, slave):
        if fd is not None:
            os.close(fd)
    if child is not None and child.poll() is None:
        child.kill()
        child.wait(timeout=1)
"""#

private func waitForTerminalLossHarness(_ process: Process, seconds: TimeInterval) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    return !process.isRunning
}

@Test(.timeLimit(.minutes(1)))
func terminalLossWithoutControllingTerminalExitsWith129() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-terminal-loss-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDir = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("harness-output")
    try Data().write(to: outputURL)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    // First use the sibling executable path from RpcModeTests.swift.
    // Swift Testing can run through a helper outside the build directory.
    let testExecutable = ProcessInfo.processInfo.arguments[0]
    let binaryDirectory = URL(fileURLWithPath: testExecutable).deletingLastPathComponent()
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        binaryDirectory.appendingPathComponent("pi-coding-agent"),
        repo.appendingPathComponent(".build/debug/pi-coding-agent"),
        repo.appendingPathComponent(".build/out/Products/Debug/pi-coding-agent"),
    ]
    let cliURL = try #require(candidates.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }, "The built pi-coding-agent executable was not found.")
    let harness = Process()
    harness.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    harness.arguments = ["python3", "-c", terminalLossHarness, cliURL.path, agentDir.path]
    // A file prevents a full output pipe from blocking the harness.
    harness.standardOutput = output
    harness.standardError = output
    try harness.run()
    if !waitForTerminalLossHarness(harness, seconds: 20) {
        // Python handles SIGTERM and kills its child in the finally block.
        harness.terminate()
        if !waitForTerminalLossHarness(harness, seconds: 2) {
            _ = kill(harness.processIdentifier, SIGKILL)
            guard waitForTerminalLossHarness(harness, seconds: 2) else {
                throw TerminalLossTestError.cleanupTimedOut
            }
        }
        throw TerminalLossTestError.harnessTimedOut
    }
    let data = try Data(contentsOf: outputURL)
    let diagnostic = String(decoding: data, as: UTF8.self)
    try #require(harness.terminationReason == .exit && harness.terminationStatus == 0,
                 "Terminal loss harness failed: \(diagnostic)")
    let result = try JSONDecoder().decode(TerminalLossResult.self, from: data)
    #expect(result.drewFrame, "The CLI did not draw a frame before terminal loss.")
    #expect(result.outputBytes > 0)
    #expect(result.exitStatus == 129)
    #expect(result.elapsedSeconds <= 5)
    #expect(!FileManager.default.fileExists(atPath: agentDir.appendingPathComponent("crashes.json").path))
}
