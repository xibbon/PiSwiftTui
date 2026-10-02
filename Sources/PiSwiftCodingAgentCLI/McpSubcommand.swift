import AppKit
import ArgumentParser
import Darwin
import Foundation
import PiSwiftCodingAgent
import PiSwiftMCP

struct McpSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Configure and check MCP servers and sign in to OAuth servers",
        subcommands: [McpAddSubcommand.self, McpRemoveSubcommand.self, McpListSubcommand.self,
                      McpLoginSubcommand.self, McpLogoutSubcommand.self]
    )

    mutating func run() async throws { print(mcpCommandHelp) }
}

struct McpAddSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add or replace a server in mcp.json")

    @Flag(name: [.customShort("l"), .customLong("local")]) var local = false
    @Option(name: .customLong("url")) var url: String?
    @Option(name: .customLong("env")) var environment: [String] = []
    @Option(name: .customLong("cwd")) var cwd: String?
    @Option(name: .customLong("header")) var headers: [String] = []
    @Option(name: .customLong("bearer-token-env-var")) var bearerTokenEnvVar: String?
    @Option(name: .customLong("oauth-client-id")) var oauthClientID: String?
    @Option(name: .customLong("oauth-client-secret")) var oauthClientSecret: String?
    @Option(name: .customLong("oauth-callback-port")) var oauthCallbackPort: String?
    @Option(name: .customLong("exposure")) var exposure: String?
    @Argument var server: String
    @Argument(parsing: .postTerminator) var command: [String] = []

    mutating func run() async throws {
        var args = ["add", server]
        if local { args.append("--local") }
        for (flag, value) in [("url", url), ("cwd", cwd), ("bearer-token-env-var", bearerTokenEnvVar),
                              ("oauth-client-id", oauthClientID), ("oauth-client-secret", oauthClientSecret),
                              ("oauth-callback-port", oauthCallbackPort), ("exposure", exposure)] {
            if let value { args += ["--" + flag, value] }
        }
        for value in environment { args += ["--env", value] }
        for value in headers { args += ["--header", value] }
        if !command.isEmpty { args += ["--"] + command }
        await finishMcpCommand(args)
    }
}

struct McpRemoveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a server from mcp.json")
    @Flag(name: [.customShort("l"), .customLong("local")]) var local = false
    @Argument var server: String
    mutating func run() async throws { await finishMcpCommand(["remove", server] + (local ? ["--local"] : [])) }
}

struct McpListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show state, tools, and errors (exits 1 on failure)")
    @Flag(name: .customLong("json")) var json = false
    mutating func run() async throws { await finishMcpCommand(["list"] + (json ? ["--json"] : [])) }
}

struct McpLoginSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Sign in through the browser")
    @Argument var server: String
    @Option(name: .customLong("timeout")) var timeout = "300"
    mutating func run() async throws { await finishMcpCommand(["login", server, "--timeout", timeout]) }
}

struct McpLogoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Delete the stored OAuth credentials")
    @Argument var server: String
    mutating func run() async throws { await finishMcpCommand(["logout", server]) }
}

let mcpCommandHelp = """
Usage:
  \(APP_NAME) mcp add <server> [options] -- <command> [args...]
  \(APP_NAME) mcp add <server> [options] --url <url>
  \(APP_NAME) mcp remove <server> [-l]
  \(APP_NAME) mcp list [--json]
  \(APP_NAME) mcp login <server> [--timeout <seconds>]
  \(APP_NAME) mcp logout <server>

Configure and check MCP servers and sign in to OAuth servers without starting a session.
Reads ~/\(CONFIG_DIR_NAME)/agent/mcp.json and, in trusted projects, \(CONFIG_DIR_NAME)/mcp.json.

Commands:
  add <server>            Add or replace a server in mcp.json
  remove <server>         Remove a server from mcp.json
  list                    Show state, tools, and errors (exits 1 on failure)
  login <server>          Sign in through the browser
  logout <server>         Delete the stored OAuth credentials

Options for add and remove:
  -l, --local             Use \(CONFIG_DIR_NAME)/mcp.json in the current project instead of the global file

Options for add:
  --url <url>             Streamable HTTP server URL (instead of a command)
  --env <KEY=VALUE>       Environment variable for a stdio server (repeatable)
  --cwd <dir>             Working directory for a stdio server
  --header <KEY=VALUE>    HTTP header (repeatable)
  --bearer-token-env-var <NAME>
                          Send "Authorization: Bearer ${NAME}"
  --oauth-client-id <id>  Pre-registered OAuth client id
  --oauth-client-secret <secret>
                          OAuth client secret (may be ${NAME} or !command)
  --oauth-callback-port <port>
                          Fixed OAuth callback port
  --exposure <mode>       codemode (default), deferred, direct, or hidden

Other options:
  --json                  Print the list as JSON
  --timeout <seconds>     How long login waits for the browser (default: 300)
"""

private let mcpHelpHint = "Use \"\(APP_NAME) mcp --help\" for usage."

struct McpCommandOptions: Sendable {
    var cwd: URL
    var agentDir: URL
    var credentials: McpOAuthCredentialStore?
    var openURL: (@Sendable (URL) async throws -> Void)?
    var log: @Sendable (String) -> Void = { print($0) }
    var error: @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    var createTransport: McpTransportFactory = createDefaultMcpTransport
    var makePresenter: (@Sendable (McpOAuthConfig, Double, @escaping @Sendable (URL) async throws -> Void) throws -> any McpSignInPresenter)?
    var oauthHTTP: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
}

private func finishMcpCommand(_ args: [String]) async {
    markCodingAgentEnvironment()
    let code = await runMcpCommand(args, options: McpCommandOptions(
        cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        agentDir: URL(fileURLWithPath: getAgentDir())))
    if code != 0 { Darwin.exit(code) }
}

// MCP has its own option grammar and exit codes. Do not apply session argument rewrites to it.
func runMcpCLI(_ args: [String]) async {
    if !args.contains("--help"), !args.contains("-h"), mcpHasKnownOptionSyntax(args) {
        do {
            var command = try PiCodingAgentCLI.parseAsRoot(preprocessMcpArguments(["mcp"] + args))
            if var asyncCommand = command as? any AsyncParsableCommand { try await asyncCommand.run() }
            else { try command.run() }
            return
        } catch {
            // The source grammar supplies the diagnostic and exit code for parse errors.
        }
    }
    await finishMcpCommand(args)
}

private func mcpHasKnownOptionSyntax(_ args: [String]) -> Bool {
    guard let command = args.first else { return true }
    let known: [String: McpOptionKind]
    switch command {
    case "add": known = ["local": .flag, "url": .value, "env": .list, "cwd": .value,
        "header": .list, "bearer-token-env-var": .value, "oauth-client-id": .value,
        "oauth-client-secret": .value, "oauth-callback-port": .value, "exposure": .value]
    case "remove": known = ["local": .flag]
    case "list": known = ["json": .flag]
    case "login": known = ["timeout": .value]
    case "logout": known = [:]
    default: return false
    }
    return parseMcpOptions(Array(args.dropFirst()), known: known, error: { _ in },
        maxPositionals: command == "add" ? 2 : .max) != nil
}

private enum McpOptionKind: Equatable { case flag, value, list }
private struct McpParsedOptions {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil || lists[name] != nil }
}

private func parseMcpOptions(_ args: [String], known: [String: McpOptionKind],
                             error: (String) -> Void, maxPositionals: Int = .max) -> McpParsedOptions? {
    var result = McpParsedOptions()
    var index = 0
    while index < args.count {
        let arg = args[index] == "-l" ? "--local" : args[index]
        if arg == "--" || result.positional.count >= maxPositionals {
            result.positional += args.dropFirst(arg == "--" ? index + 1 : index)
            break
        }
        if !arg.hasPrefix("--") { result.positional.append(arg); index += 1; continue }
        let name = String(arg.dropFirst(2))
        guard let kind = known[name] else { error("Unknown option \(arg).\n\(mcpHelpHint)"); return nil }
        if kind == .flag { result.flags.insert(name); index += 1; continue }
        index += 1
        guard index < args.count else { error("\(arg) needs a value."); return nil }
        if kind == .list { result.lists[name, default: []].append(args[index]) }
        else { result.values[name] = args[index] }
        index += 1
    }
    return result
}

func runMcpCommand(_ args: [String], options: McpCommandOptions) async -> Int32 {
    guard let command = args.first, command != "help", !args.contains("--help"), !args.contains("-h") else {
        options.log(mcpCommandHelp)
        return 0
    }
    let rest = Array(args.dropFirst())
    let projectConfig = options.cwd.appendingPathComponent(CONFIG_DIR_NAME + "/mcp.json")
    if command == "add" { return addMcpCommand(rest, projectConfig: projectConfig, options: options) }
    if command == "remove" { return removeMcpCommand(rest, projectConfig: projectConfig, options: options) }
    let projectTrusted = mcpProjectTrusted(options)
    let loaded = loadMcpConfig(agentDir: options.agentDir, cwd: options.cwd, projectTrusted: projectTrusted)
    let note = !projectTrusted && FileManager.default.fileExists(atPath: projectConfig.path)
        ? "\(projectConfig.path) is ignored because the project is not trusted. Start \(APP_NAME) in the project to trust it." : nil
    let credentials = options.credentials ?? McpOAuthCredentialStore(agentDir: options.agentDir)
    switch command {
    case "list":
        guard let parsed = parseMcpOptions(rest, known: ["json": .flag], error: options.error) else { return 1 }
        guard parsed.positional.isEmpty else { options.error("Usage: \(APP_NAME) mcp list [--json]\n\(mcpHelpHint)"); return 1 }
        let report = await inspectMcpServers(loaded, cwd: options.cwd, credentials: credentials, note: note,
            log: McpServerLog(path: options.agentDir.appendingPathComponent("mcp.log")), createTransport: options.createTransport)
        return printMcpList(report, json: parsed.flags.contains("json"), options: options)
    case "login", "logout":
        guard let parsed = parseMcpOptions(rest, known: command == "login" ? ["timeout": .value] : [:], error: options.error) else { return 1 }
        guard parsed.positional.count == 1, let name = parsed.positional.first, !name.isEmpty else {
            options.error("Usage: \(APP_NAME) mcp \(command) <server>\n\(mcpHelpHint)"); return 1
        }
        guard let entry = loaded.servers.first(where: { $0.name == name }) else {
            let configured = loaded.servers.map(\.name).joined(separator: ", ")
            options.error("No MCP server named \"\(name)\".\(note.map { " " + $0 } ?? "") Configured: \(configured.isEmpty ? "none" : configured).")
            return 1
        }
        let connection = McpServerConnection(entry: entry, cwd: options.cwd, createTransport: options.createTransport,
            credentials: credentials, log: McpServerLog(path: options.agentDir.appendingPathComponent("mcp.log")))
        guard let url = await connection.oauthURL else {
            options.error("MCP server \"\(name)\" does not use OAuth. Only HTTP servers without an Authorization header do.")
            return 1
        }
        if command == "logout" {
            do {
                let removed = try credentials.remove(url)
                options.log(removed ? "Signed out of MCP server \"\(name)\"." : "No stored credentials for MCP server \"\(name)\".")
                return 0
            } catch { options.error(error.localizedDescription); return 1 }
        }
        let timeout = mcpNumber(parsed.values["timeout"] ?? "300")
        guard timeout.isFinite, timeout > 0 else { options.error("--timeout must be a positive number of seconds."); return 1 }
        let code = await loginMcpCommand(entry, connection: connection, url: url, timeout: timeout,
            options: options, credentials: credentials)
        await connection.close()
        return code
    default:
        options.error("Unknown mcp command \"\(command)\".\n\(mcpHelpHint)")
        return 1
    }
}

private func mcpProjectTrusted(_ options: McpCommandOptions) -> Bool {
    SettingsManager.create(options.cwd.path, options.agentDir.path, projectTrusted: false).getProjectTrust(options.cwd.path) == true
}

private func mcpNumber(_ raw: String) -> Double {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return 0 }
    if (text.first == "+" || text.first == "-"),
       ["0x", "0b", "0o"].contains(where: { text.dropFirst().lowercased().hasPrefix($0) }) { return .nan }
    for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where text.lowercased().hasPrefix(prefix) {
        let digits = text.dropFirst(2)
        guard !digits.isEmpty else { return .nan }
        var result: Double = 0
        for digit in digits {
            guard let value = digit.hexDigitValue, value < radix, digit.isASCII else { return .nan }
            result = result * Double(radix) + Double(value)
        }
        return result
    }
    return Double(text) ?? .nan
}

// Match Math.round(timeoutMs / 1000).toString(), including overflow in timeout * 1000.
private func mcpTimeoutText(_ seconds: Double) -> String {
    let rounded = ((seconds * 1_000) / 1_000).rounded(.toNearestOrAwayFromZero)
    if rounded == .infinity { return "Infinity" }
    if rounded == 0 { return "0" }
    let parts = String(rounded).lowercased().split(separator: "e", omittingEmptySubsequences: false)
    var significand = String(parts[0])
    if significand.hasSuffix(".0") { significand.removeLast(2) }
    guard parts.count == 2, let exponent = Int(parts[1]) else { return significand }
    if rounded >= 1e21 { return significand + "e" + (exponent >= 0 ? "+" : "") + String(exponent) }
    let decimalPosition = (significand.firstIndex(of: ".").map { significand.distance(from: significand.startIndex, to: $0) }
        ?? significand.count) + exponent
    let digits = significand.replacingOccurrences(of: ".", with: "")
    if decimalPosition >= digits.count { return digits + String(repeating: "0", count: decimalPosition - digits.count) }
    let split = digits.index(digits.startIndex, offsetBy: decimalPosition)
    return String(digits[..<split]) + "." + String(digits[split...])
}

private func parseMcpPairs(_ option: String, pairs: [String]?, error: (String) -> Void) -> [String: String]? {
    var result: [String: String] = [:]
    for pair in pairs ?? [] {
        guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
            error("--\(option) expects KEY=VALUE, got \"\(pair)\"."); return nil
        }
        result[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
    }
    return result
}

private func addMcpCommand(_ args: [String], projectConfig: URL, options: McpCommandOptions) -> Int32 {
    guard let parsed = parseMcpOptions(args, known: ["local": .flag, "url": .value, "env": .list,
        "cwd": .value, "header": .list, "bearer-token-env-var": .value, "oauth-client-id": .value,
        "oauth-client-secret": .value, "oauth-callback-port": .value, "exposure": .value], error: options.error, maxPositionals: 2) else { return 1 }
    let command = Array(parsed.positional.dropFirst())
    let url = parsed.values["url"]
    guard let name = parsed.positional.first, !name.isEmpty, (url == nil) != command.isEmpty else {
        options.error("Usage: \(APP_NAME) mcp add <server> [options] (--url <url> | -- <command> [args...])\n\(mcpHelpHint)")
        return 1
    }
    let httpOnly = ["header", "bearer-token-env-var", "oauth-client-id", "oauth-client-secret", "oauth-callback-port"]
    if let misplaced = (url == nil ? httpOnly : ["env", "cwd"]).first(where: { parsed.has($0) }) {
        options.error("--\(misplaced) only applies to \(url == nil ? "HTTP servers (--url)" : "stdio servers").")
        return 1
    }
    var value: [String: Any] = [:]
    if let url {
        guard var headers = parseMcpPairs("header", pairs: parsed.lists["header"], error: options.error) else { return 1 }
        if let bearer = parsed.values["bearer-token-env-var"] { headers["Authorization"] = "Bearer ${\(bearer)}" }
        value["url"] = url
        if !headers.isEmpty { value["headers"] = headers }
        var oauth: [String: Any] = [:]
        oauth["clientId"] = parsed.values["oauth-client-id"]
        oauth["clientSecret"] = parsed.values["oauth-client-secret"]
        if let port = parsed.values["oauth-callback-port"] { oauth["callbackPort"] = mcpNumber(port) }
        if !oauth.isEmpty { value["oauth"] = oauth }
    } else {
        guard let env = parseMcpPairs("env", pairs: parsed.lists["env"], error: options.error) else { return 1 }
        value["command"] = command.first
        if command.count > 1 { value["args"] = Array(command.dropFirst()) }
        if !env.isEmpty { value["env"] = env }
        value["cwd"] = parsed.values["cwd"]
    }
    value["exposure"] = parsed.values["exposure"]
    if let invalid = validateMcpServerConfig(name: name, value: value) { options.error(invalid); return 1 }
    let path = parsed.flags.contains("local") ? projectConfig : options.agentDir.appendingPathComponent("mcp.json")
    let scope = parsed.flags.contains("local") ? "project" : "global"
    do {
        let config = try JSONDecoder().decode(McpServerConfig.self, from: JSONSerialization.data(withJSONObject: value))
        let replaced = try addMcpServerConfig(path: path, name: name, config: config)
        options.log("\(replaced ? "Replaced" : "Added") \(scope) MCP server \"\(name)\" in \(path.path).")
        if scope == "project", !mcpProjectTrusted(options) {
            options.log("The project is not trusted, so \(path.path) is ignored until you start \(APP_NAME) in the project and trust it.")
        }
        let signIn = config.url != nil && !(config.headers ?? [:]).keys.contains { $0.lowercased() == "authorization" }
        options.log("Check it with: \(APP_NAME) mcp list\(signIn ? ". If it requires sign-in: \(APP_NAME) mcp login \(name)" : "")")
        return 0
    } catch {
        options.error("Could not update \(path.path): \(error.localizedDescription)")
        return 1
    }
}

private func removeMcpCommand(_ args: [String], projectConfig: URL, options: McpCommandOptions) -> Int32 {
    guard let parsed = parseMcpOptions(args, known: ["local": .flag], error: options.error) else { return 1 }
    guard parsed.positional.count == 1, let name = parsed.positional.first, !name.isEmpty else {
        options.error("Usage: \(APP_NAME) mcp remove <server> [-l]\n\(mcpHelpHint)"); return 1
    }
    let project = parsed.flags.contains("local")
    let path = project ? projectConfig : options.agentDir.appendingPathComponent("mcp.json")
    let scope = project ? "project" : "global"
    do {
        if try removeMcpServerConfig(path: path, name: name) {
            options.log("Removed \(scope) MCP server \"\(name)\" from \(path.path).")
            return 0
        }
    } catch { options.error("Could not update \(path.path): \(error.localizedDescription)"); return 1 }
    let other = loadMcpConfig(agentDir: options.agentDir, cwd: options.cwd, projectTrusted: true).servers.first {
        $0.name == name && $0.scope.rawValue != scope
    }
    let hint = other.map { " It is defined in \($0.source); \($0.scope == .project ? "use --local" : "omit --local")." } ?? ""
    options.error("No \(scope) MCP server named \"\(name)\" in \(path.path).\(hint)")
    return 1
}

private func printMcpList(_ report: McpListReport, json: Bool, options: McpCommandOptions) -> Int32 {
    if json {
        do { options.log(String(decoding: try report.jsonData(), as: UTF8.self)) }
        catch { options.error(error.localizedDescription); return 1 }
        return report.failed ? 1 : 0
    }
    if report.servers.isEmpty, report.errors.isEmpty {
        options.log("No MCP servers configured. Add them to \(options.agentDir.appendingPathComponent("mcp.json").path) or .pi/mcp.json.")
    }
    for server in report.servers {
        let state: String
        if server.state == "connected" { state = "connected, \(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")" }
        else { state = server.state == "needs-auth" ? "needs sign-in" : server.state }
        options.log("\(server.name): \(state) (\(server.exposure.rawValue), \(server.scope.rawValue))")
        options.log("  \(server.transport)")
        if server.state == "needs-auth" { options.log("  sign in with: \(APP_NAME) mcp login \(server.name)") }
        if !server.tools.isEmpty {
            let tools = server.tools.map { tool in server.toolExposure?[tool].map { "\(tool) [\($0.rawValue)]" } ?? tool }
            options.log("  tools: \(tools.joined(separator: ", "))")
        }
        if let resources = server.resources { options.log("  resources: \(resources), URI templates: \(server.resourceTemplates ?? 0)") }
        if let error = server.error { options.log("  " + error.replacingOccurrences(of: "\n", with: "\n  ")) }
    }
    for error in report.errors { options.log("config error: " + error) }
    if let note = report.note { options.log(note) }
    return report.failed ? 1 : 0
}

private func loginMcpCommand(_ entry: McpServerEntry, connection: McpServerConnection, url: URL,
                             timeout: Double, options: McpCommandOptions, credentials: McpOAuthCredentialStore) async -> Int32 {
    let name = entry.name
    do {
        try await connection.connect()
        options.log("Already signed in to MCP server \"\(name)\" (\(await connection.tools.count) tools).")
        return 0
    } catch {
        if await connection.state != .needsAuth {
            options.error("MCP server \"\(name)\" failed to connect: \(await connection.error ?? "unknown error")")
            return 1
        }
    }
    do {
        let settings = try connection.oauthSettings()
        let open: @Sendable (URL) async throws -> Void = { authorizationURL in
            options.log("Sign in to MCP server \"\(name)\" in your browser:\n\(authorizationURL.absoluteString)")
            if let openURL = options.openURL { try await openURL(authorizationURL) }
            else { _ = await MainActor.run { NSWorkspace.shared.open(authorizationURL) } }
        }
        let presenter: any McpSignInPresenter
        if let makePresenter = options.makePresenter { presenter = try makePresenter(settings, timeout, open) }
        else {
            let paste: (@Sendable () async throws -> String)?
            if isatty(STDIN_FILENO) == 1 && options.openURL == nil {
                paste = { @Sendable in try await readMcpRedirectURL() }
            } else { paste = nil }
            presenter = try makeMcpMacOSSignInPresenter(settings: settings, callbackTimeoutSeconds: timeout,
                pasteRedirectURL: paste, openAuthorizationURL: open)
        }
        try await signInMcpServer(serverURL: url, credentials: credentials, settings: settings,
            challenge: await connection.challenge, presenter: presenter, http: options.oauthHTTP)
    } catch {
        if error is CancellationError || error is McpCLIInputCancelled || error.localizedDescription == "MCP sign-in timed out" {
            options.error("Sign-in to MCP server \"\(name)\" was cancelled or not completed within \(mcpTimeoutText(timeout)) seconds.")
        } else { options.error("Sign-in to MCP server \"\(name)\" failed: \(error.localizedDescription)") }
        return 1
    }
    await connection.clearOAuthChallenge()
    do { try await connection.reconnect() }
    catch { options.error("Signed in, but \(error.localizedDescription)"); return 1 }
    options.log("Signed in to MCP server \"\(name)\" (\(await connection.tools.count) tools).")
    return 0
}

private struct McpCLIInputCancelled: Error {}

private func readMcpRedirectURL() async throws -> String {
    fputs("If the browser cannot reach this machine, paste the URL it was redirected to: ", stderr)
    fflush(stderr)
    var input = Data()
    while true {
        try Task.checkCancellation()
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 0) > 0 {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { throw McpCLIInputCancelled() }
            if byte == 10 { return String(decoding: input, as: UTF8.self) }
            if byte != 13 { input.append(byte) }
        } else { try await Task.sleep(for: .milliseconds(20)) }
    }
}

// ArgumentParser uses postTerminator; upstream also accepts a command without `--`.
func preprocessMcpArguments(_ args: [String]) -> [String] {
    guard args.count >= 2, args[0] == "mcp", args[1] == "add" else { return args }
    let valueOptions: Set<String> = ["--url", "--env", "--cwd", "--header", "--bearer-token-env-var",
        "--oauth-client-id", "--oauth-client-secret", "--oauth-callback-port", "--exposure"]
    var index = 2
    var positionals = 0
    while index < args.count {
        let argument = args[index]
        if argument == "--" { return args }
        if valueOptions.contains(argument) { index += 2; continue }
        if argument == "-l" || argument == "--local" { index += 1; continue }
        if !argument.hasPrefix("--") {
            positionals += 1
            if positionals == 2 { var result = args; result.insert("--", at: index); return result }
        }
        index += 1
    }
    return args
}
