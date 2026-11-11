import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

protocol InteractiveFooterDataProvider: FooterDataProviding {
    func setExtensionStatus(_ key: String, _ text: String?)
    func dispose()
}

extension FooterDataProvider: InteractiveFooterDataProvider {}

/// Read the branch from the session folder after a cross-folder switch.
/// The library provider has no cwd argument and reads the process folder.
final class SessionFooterDataProvider: InteractiveFooterDataProvider, Sendable {
    private let cwd: String
    private let statuses = LockedState<[String: String]>([:])

    init(cwd: String) { self.cwd = cwd }

    func getGitBranch() -> String? {
        var directory = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            let head: URL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    head = dotGit.appendingPathComponent("HEAD")
                } else {
                    guard let entry = try? String(contentsOf: dotGit, encoding: .utf8),
                          entry.hasPrefix("gitdir: ") else { return nil }
                    let path = entry.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    head = URL(fileURLWithPath: path, relativeTo: directory).appendingPathComponent("HEAD")
                }
                guard let value = try? String(contentsOf: head, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                return value.hasPrefix("ref: refs/heads/")
                    ? String(value.dropFirst("ref: refs/heads/".count)) : "detached"
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    func getExtensionStatuses() -> [String: String] { statuses.withLock { $0 } }

    func onBranchChange(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        _ = callback
        return {}
    }

    func setExtensionStatus(_ key: String, _ text: String?) {
        statuses.withLock { entries in entries[key] = text }
    }

    func dispose() { statuses.withLock { $0.removeAll() } }
}
