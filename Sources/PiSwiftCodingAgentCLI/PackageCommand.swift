import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

private enum PackageCommand: String {
    case install
    case remove
    case update
    case list
}

private struct PackageCommandOptions {
    var command: PackageCommand
    var source: String?
    var local: Bool
    var help: Bool
    var invalidOption: String?
}

private let packageCommandExitCodeStore = LockedState<Int32?>(nil)

@discardableResult
func consumePackageCommandExitCode() -> Int32? {
    packageCommandExitCodeStore.withLock { code in
        defer { code = nil }
        return code
    }
}

private func setPackageCommandExitCode(_ code: Int32) {
    packageCommandExitCodeStore.withLock { $0 = code }
}

private func packageCommandUsage(_ command: PackageCommand) -> String {
    switch command {
    case .install:
        return "\(APP_NAME) install <source> [-l]"
    case .remove:
        return "\(APP_NAME) remove <source> [-l]"
    case .update:
        return "\(APP_NAME) update [source]"
    case .list:
        return "\(APP_NAME) list"
    }
}

private func printPackageCommandHelp(_ command: PackageCommand) {
    print("Usage:")
    print("  \(packageCommandUsage(command))")
}

func handlePackageCommand(
    _ args: [String],
    approve: Bool = false,
    noApprove: Bool = false,
    noExtensions: Bool = false,
    offline: Bool = false
) async -> Bool {
    _ = consumePackageCommandExitCode()
    guard let options = parsePackageCommand(args) else { return false }

    if options.help {
        printPackageCommandHelp(options.command)
        return true
    }

    if let invalidOption = options.invalidOption {
        fputs("Unknown option \(invalidOption) for \"\(options.command.rawValue)\".\n", stderr)
        fputs("Use \"\(APP_NAME) --help\" or \"\(packageCommandUsage(options.command))\".\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    if (options.command == .install || options.command == .remove),
       options.source == nil || options.source?.isEmpty == true {
        fputs("Missing \(options.command.rawValue) source.\n", stderr)
        fputs("Usage: \(packageCommandUsage(options.command))\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    if offline && options.command == .install {
        fputs("Offline mode is enabled; package install is unavailable.\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    let cwd = FileManager.default.currentDirectoryPath
    let agentDir = getAgentDir()
    let authStorage = AuthStorage.create(getAuthPath())
    let clientIdentityPolicy = CLIClientIdentityPolicy(SettingsManager.create(cwd, agentDir, projectTrusted: false))
    let modelRegistry = ModelRegistry(authStorage, agentDir, clientIdentityProvider: {
        clientIdentityPolicy.identity()
    })
    let trustChoice = projectTrustChoice(approve: approve, noApprove: noApprove)
    let trustContext = await resolveProjectTrustForCLI(
        cwd: cwd,
        agentDir: agentDir,
        modelRegistry: modelRegistry,
        eventBus: createEventBus(),
        choice: trustChoice,
        persistChoice: trustChoice != nil,
        noExtensions: noExtensions,
        mode: .print,
        hasUI: false
    )
    let settingsManager = trustContext.settingsManager
    clientIdentityPolicy.useSettings(settingsManager)
    for error in settingsManager.drainErrors() {
        fputs("Warning (package command, \(error.scope) settings): \(error.message)\n", stderr)
    }
    if options.local && !trustContext.trust.trusted {
        fputs("Project package changes require a trusted project. Re-run with --approve to allow project-local package settings.\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }
    let packageManager = DefaultPackageManager(
        cwd: cwd,
        agentDir: agentDir,
        settingsManager: settingsManager,
        projectTrusted: trustContext.trust.trusted,
        offline: offline
    )

    let updateMessages = LockedState<[String]>([])
    let updateWarningCount = LockedState(0)
    packageManager.setProgressCallback { event in
        switch event.type {
        case "start":
            if let message = event.message {
                fputs("\(message)\n", stdout)
            }
        case "error":
            if let message = event.message {
                fputs("Error: \(message)\n", stderr)
            }
        case "progress":
            if let message = event.message {
                updateWarningCount.withLock { $0 += 1 }
                fputs("\(message)\n", stdout)
            }
        case "result":
            if event.action == "update", let message = event.message {
                updateMessages.withLock { $0.append(message) }
            }
        default:
            break
        }
    }

    do {
        switch options.command {
        case .install:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing install source.\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            try await packageManager.install(source, options: PackageResolveOptions(local: options.local))
            _ = packageManager.addSourceToSettings(source, local: options.local)
            print("Installed \(source)")
        case .remove:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing remove source.\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            try await packageManager.remove(source, options: PackageResolveOptions(local: options.local))
            let removed = packageManager.removeSourceFromSettings(source, local: options.local)
            if !removed {
                fputs("No matching package found for \(source).\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            print("Removed \(source)")
        case .list:
            let globalPackages = settingsManager.getGlobalSettings().packages ?? []
            let projectPackages = settingsManager.getProjectSettings().packages ?? []
            if globalPackages.isEmpty && projectPackages.isEmpty {
                print("No packages installed.")
                return true
            }

            func formatPackage(_ pkg: PackageSource, scope: String) {
                let source = packageSourceString(pkg)
                let display = isFiltered(pkg) ? "\(source) (filtered)" : source
                print("  \(display)")
                if let path = packageManager.getInstalledPath(source, scope: scope) {
                    print("    \(path)")
                }
            }

            if !globalPackages.isEmpty {
                print("User packages:")
                for pkg in globalPackages {
                    formatPackage(pkg, scope: "user")
                }
            }

            if !projectPackages.isEmpty {
                if !globalPackages.isEmpty { print("") }
                print("Project packages:")
                for pkg in projectPackages {
                    formatPackage(pkg, scope: "project")
                }
            }
        case .update:
            let result = try await packageManager.updateWithResult(options.source)
            print(packageUpdateSummaryText(
                updated: updateMessages.withLock { $0 },
                warningCount: max(result.warningCount, updateWarningCount.withLock { $0 }),
                skippedOffline: result.skippedOffline,
                source: options.source
            ))
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        setPackageCommandExitCode(1)
    }

    return true
}

func packageUpdateSummaryText(updated: [String], warningCount: Int, skippedOffline: Bool, source: String?) -> String {
    if skippedOffline { return "Skipped package updates (offline mode)" }
    if !updated.isEmpty {
        return "Updated \(updated.count) package\(updated.count == 1 ? "" : "s"):\n" +
            updated.map { "  \($0)" }.joined(separator: "\n")
    }
    if warningCount > 0 {
        return source.map { "\($0) was not updated, see the warnings above" }
            ?? "No packages were updated, see the warnings above"
    }
    return source.map { "\($0) is already up to date" } ?? "Packages are already up to date"
}

private func parsePackageCommand(_ args: [String]) -> PackageCommandOptions? {
    guard let command = args.first else { return nil }
    // "uninstall" is an alias for "remove"
    let normalizedCommand = command == "uninstall" ? "remove" : command
    guard let parsed = PackageCommand(rawValue: normalizedCommand) else {
        return nil
    }

    var local = false
    var help = false
    var invalidOption: String?
    var source: String?
    for arg in args.dropFirst() {
        if arg == "-h" || arg == "--help" {
            help = true
            continue
        }
        if arg == "-l" || arg == "--local" {
            if parsed == .install || parsed == .remove {
                local = true
            } else if invalidOption == nil {
                invalidOption = arg
            }
            continue
        }
        if arg.hasPrefix("-") {
            if invalidOption == nil {
                invalidOption = arg
            }
            continue
        }
        if source == nil {
            source = arg
        }
    }

    return PackageCommandOptions(
        command: parsed,
        source: source,
        local: local,
        help: help,
        invalidOption: invalidOption
    )
}

private enum PackageSourceAction {
    case add
    case remove
}

private func updatePackageSources(
    _ settingsManager: SettingsManager,
    source: String,
    local: Bool,
    action: PackageSourceAction
) {
    let currentSettings = local ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings()
    let currentPackages = currentSettings.packages ?? []

    let nextPackages: [PackageSource]
    switch action {
    case .add:
        let exists = currentPackages.contains { packageSourcesMatch($0, source) }
        nextPackages = exists ? currentPackages : currentPackages + [.simple(source)]
    case .remove:
        nextPackages = currentPackages.filter { !packageSourcesMatch($0, source) }
    }

    if local {
        settingsManager.setProjectPackages(nextPackages)
    } else {
        settingsManager.setPackages(nextPackages)
    }
}

private func packageSourceString(_ pkg: PackageSource) -> String {
    switch pkg {
    case .simple(let value):
        return value
    case .filtered(let value):
        return value.source
    }
}

private func isFiltered(_ pkg: PackageSource) -> Bool {
    if case .filtered = pkg { return true }
    return false
}

private func packageSourcesMatch(_ a: PackageSource, _ b: String) -> Bool {
    let aSource = packageSourceString(a)
    return sourcesMatch(aSource, b)
}

private func sourcesMatch(_ a: String, _ b: String) -> Bool {
    let left = normalizePackageSource(a)
    let right = normalizePackageSource(b)
    return left.type == right.type && left.key == right.key
}

private func normalizePackageSource(_ source: String) -> (type: String, key: String) {
    if source.hasPrefix("npm:") {
        let spec = source.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let (name, _) = parseNpmSpec(String(spec))
        return ("npm", name)
    }
    if source.hasPrefix("git:") {
        let repo = source.dropFirst(4).split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    if source.hasPrefix("https://") || source.hasPrefix("http://") {
        let repo = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    return ("local", source)
}

private func parseNpmSpec(_ spec: String) -> (name: String, version: String?) {
    if let atIndex = spec.lastIndex(of: "@"), atIndex != spec.startIndex {
        let name = String(spec[..<atIndex])
        let version = String(spec[spec.index(after: atIndex)...])
        if !name.isEmpty && !version.isEmpty {
            return (name, version)
        }
    }
    return (spec, nil)
}
