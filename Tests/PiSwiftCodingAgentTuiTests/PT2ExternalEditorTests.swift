import Foundation
import Darwin
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@Test func pt2ExternalEditorUsesPrivateTemporaryFileAndCleansIt() {
    var capturedDirectory: URL?
    let result = editInExternalEditor(command: "fake --edit", content: "original") { command, arguments in
        #expect(command == "fake")
        #expect(arguments.first == "--edit")
        guard let path = arguments.last else { return .launchFailed }
        let file = URL(fileURLWithPath: path)
        capturedDirectory = file.deletingLastPathComponent()
        #expect(file.lastPathComponent == "prompt.md")
        #expect((try? String(contentsOf: file, encoding: .utf8)) == "original")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        #expect((permissions?.intValue ?? 0) & 0o077 == 0)
        try? "\u{FEFF}edited\n".write(to: file, atomically: true, encoding: .utf8)
        return .code(0)
    }
    #expect(result == .complete("edited"))
    if let capturedDirectory { #expect(!FileManager.default.fileExists(atPath: capturedDirectory.path)) }
}

@Test func pt2ExternalEditorKeepsContentOnFailure() {
    let result = editInExternalEditor(command: "fake", content: "original") { _, arguments in
        #expect((try? String(contentsOfFile: arguments.last ?? "", encoding: .utf8)) == "original")
        return .code(1)
    }
    #expect(result == .failed("External editor exited with code 1; prompt unchanged"))
    let launch = editInExternalEditor(command: "missing", content: "original") { _, _ in .launchFailed }
    #expect(launch == .failed("Failed to launch external editor: missing"))
    let empty = editInExternalEditor(command: "fake", content: "original") { _, arguments in
        if let path = arguments.last { try? "".write(toFile: path, atomically: true, encoding: .utf8) }
        return .code(0)
    }
    #expect(empty == .complete(""))
}

@Test func pt2ExternalEditorChildProcessFailures() {
    #expect(editInExternalEditor(command: "/usr/bin/false", content: "original") ==
        .failed("External editor exited with code 1; prompt unchanged"))
    #expect(editInExternalEditor(command: "/path/that/does/not/exist/editor", content: "original") ==
        .failed("Failed to launch external editor: /path/that/does/not/exist/editor"))
}

@Test func pt2ExternalEditorCommandSelectionAndArguments() {
    var settings = Settings()
    settings.externalEditor = "code --wait"
    let manager = SettingsManager.inMemory(settings)
    let environment = ["VISUAL": "vim", "EDITOR": "ed"]
    let selected = manager.getExternalEditorCommand(environment: environment)
    #expect(selected == "code --wait")
    let result = editInExternalEditor(command: selected, content: "original") { executable, arguments in
        #expect(executable == "code")
        #expect(arguments.first == "--wait")
        #expect(arguments.count == 2)
        return .code(1)
    }
    #expect(result == .failed("External editor exited with code 1; prompt unchanged"))

    let defaultCommand = SettingsManager.inMemory().getExternalEditorCommand(environment: [:])
    #expect(defaultCommand == "nano")
    let missing = editInExternalEditor(command: defaultCommand, content: "original") { executable, arguments in
        #expect(executable == "nano")
        #expect(arguments.count == 1)
        return .launchFailed
    }
    #expect(missing == .failed("Failed to launch external editor: nano"))
    let signalled = editInExternalEditor(command: "code --wait", content: "original") { _, _ in
        .signal(SIGTERM)
    }
    #expect(signalled == .failed("External editor exited with SIGTERM; prompt unchanged"))
    #expect(SettingsManager.inMemory().getExternalEditorCommand(environment: environment) == "vim")
    #expect(SettingsManager.inMemory().getExternalEditorCommand(environment: ["EDITOR": "ed"]) == "ed")

    // Tagged external-editor.ts:19 splits on the literal space and retains empty arguments.
    _ = editInExternalEditor(command: "code  --wait", content: "original") { executable, arguments in
        #expect(executable == "code")
        #expect(arguments.dropLast() == ["", "--wait"])
        return .launchFailed
    }
}
