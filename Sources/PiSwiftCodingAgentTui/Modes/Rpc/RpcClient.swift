import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

public struct RpcClientOptions: Sendable {
    public var cliPath: String?
    public var cwd: String?
    public var env: [String: String]?
    public var provider: String?
    public var model: String?
    public var args: [String]

    public init(
        cliPath: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        provider: String? = nil,
        model: String? = nil,
        args: [String] = []
    ) {
        self.cliPath = cliPath
        self.cwd = cwd
        self.env = env
        self.provider = provider
        self.model = model
        self.args = args
    }
}

public enum RpcCommandType: String, Sendable {
    case prompt
    case steer
    case followUp = "follow_up"
    case abort
    case clearQueue = "clear_queue"
    case newSession = "new_session"
    case getState = "get_state"
    case setSessionName = "set_session_name"
    case setModel = "set_model"
    case cycleModel = "cycle_model"
    case getAvailableModels = "get_available_models"
    case setThinkingLevel = "set_thinking_level"
    case cycleThinkingLevel = "cycle_thinking_level"
    case setSteeringMode = "set_steering_mode"
    case setFollowUpMode = "set_follow_up_mode"
    case compact
    case setAutoCompaction = "set_auto_compaction"
    case setAutoRetry = "set_auto_retry"
    case abortRetry = "abort_retry"
    case bash
    case abortBash = "abort_bash"
    case getSessionStats = "get_session_stats"
    case exportHtml = "export_html"
    case switchSession = "switch_session"
    case fork
    case getForkMessages = "get_fork_messages"
    case getLastAssistantText = "get_last_assistant_text"
    case getMessages = "get_messages"
    case getCommands = "get_commands"
}

public struct RpcSessionState: Sendable {
    public var model: Model?
    public var thinkingLevel: ThinkingLevel
    public var isStreaming: Bool
    public var isCompacting: Bool
    public var steeringMode: AgentSteeringMode
    public var followUpMode: AgentFollowUpMode
    public var sessionFile: String?
    public var sessionId: String
    public var sessionName: String?
    public var autoCompactionEnabled: Bool
    public var messageCount: Int
    public var pendingMessageCount: Int

    public init(
        model: Model?,
        thinkingLevel: ThinkingLevel,
        isStreaming: Bool,
        isCompacting: Bool,
        steeringMode: AgentSteeringMode,
        followUpMode: AgentFollowUpMode,
        sessionFile: String?,
        sessionId: String,
        sessionName: String? = nil,
        autoCompactionEnabled: Bool,
        messageCount: Int,
        pendingMessageCount: Int
    ) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.isStreaming = isStreaming
        self.isCompacting = isCompacting
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.autoCompactionEnabled = autoCompactionEnabled
        self.messageCount = messageCount
        self.pendingMessageCount = pendingMessageCount
    }
}

public struct RpcCycleModelResult: Sendable {
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var isScoped: Bool

    public init(model: Model, thinkingLevel: ThinkingLevel, isScoped: Bool) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.isScoped = isScoped
    }
}

public struct RpcForkResult: Sendable {
    public var text: String
    public var cancelled: Bool

    public init(text: String, cancelled: Bool) {
        self.text = text
        self.cancelled = cancelled
    }
}

public struct RpcSlashCommand: Sendable {
    public var name: String
    public var description: String?
    public var source: String
    public var location: String?
    public var path: String?

    public init(
        name: String,
        description: String? = nil,
        source: String,
        location: String? = nil,
        path: String? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.location = location
        self.path = path
    }
}

public enum RpcHookUIRequest: Sendable {
    case select(id: String, title: String, options: [String])
    case confirm(id: String, title: String, message: String)
    case input(id: String, title: String, placeholder: String?)
    case editor(id: String, title: String, prefill: String?)
    case notify(id: String, message: String, notifyType: HookNotificationType?)
    case setStatus(id: String, statusKey: String, statusText: String?)
    case setWidget(id: String, widgetKey: String, widgetLines: [String]?)
    case setTitle(id: String, title: String)
    case setEditorText(id: String, text: String)

    public var id: String {
        switch self {
        case .select(let id, _, _),
             .confirm(let id, _, _),
             .input(let id, _, _),
             .editor(let id, _, _),
             .notify(let id, _, _),
             .setStatus(let id, _, _),
             .setWidget(let id, _, _),
             .setTitle(let id, _),
             .setEditorText(let id, _):
            return id
        }
    }
}

public enum RpcHookUIResponse: Sendable {
    case value(id: String, value: String)
    case confirmed(id: String, confirmed: Bool)
    case cancelled(id: String)

    var payload: [String: Any] {
        switch self {
        case .value(let id, let value):
            return ["type": "hook_ui_response", "id": id, "value": value]
        case .confirmed(let id, let confirmed):
            return ["type": "hook_ui_response", "id": id, "confirmed": confirmed]
        case .cancelled(let id):
            return ["type": "hook_ui_response", "id": id, "cancelled": true]
        }
    }
}

public struct RpcHookError: Sendable {
    public var hookPath: String
    public var event: String
    public var error: String
    public var stack: String?

    public init(hookPath: String, event: String, error: String, stack: String? = nil) {
        self.hookPath = hookPath
        self.event = event
        self.error = error
        self.stack = stack
    }
}

public struct RpcAgentEvent: Sendable {
    public var type: String
    public var message: AgentMessage?
    /// Kind of the streamed assistant delta (`text_delta`, `toolcall_start`, …), taken from the
    /// `assistantMessageEvent.type` field.
    public var assistantMessageEvent: String?
    /// Index of the content block this delta belongs to, for ordering reassembly.
    public var assistantMessageContentIndex: Int?
    /// Incremental payload for `text_delta` / `thinking_delta` / `tool_call_delta` events.
    public var assistantMessageDelta: String?
    /// Cumulative usage from a message_update frame.
    public var usage: Usage?
    /// Tool identity from a toolcall_start frame.
    public var assistantMessageToolCallId: String?
    public var assistantMessageToolName: String?
    /// Completed tool call from a tool_call_end frame.
    public var assistantMessageToolCall: ToolCall?
    public var messages: [AgentMessage]?
    public var toolResults: [ToolResultMessage]?
    public var toolCallId: String?
    public var toolName: String?
    public var args: [String: AnyCodable]?
    public var partialResult: AgentToolResult?
    public var result: AgentToolResult?
    public var isError: Bool?
    /// v0.99.0: set on `tool_execution_*` events of nested calls made through `ctx.executeTool()`.
    public var parentToolCallId: String?
    public var aborted: Bool?
    public var durationMs: Int?
    public var errorMessage: String?

    public init(
        type: String,
        message: AgentMessage? = nil,
        assistantMessageEvent: String? = nil,
        assistantMessageContentIndex: Int? = nil,
        assistantMessageDelta: String? = nil,
        usage: Usage? = nil,
        assistantMessageToolCallId: String? = nil,
        assistantMessageToolName: String? = nil,
        messages: [AgentMessage]? = nil,
        toolResults: [ToolResultMessage]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        args: [String: AnyCodable]? = nil,
        partialResult: AgentToolResult? = nil,
        result: AgentToolResult? = nil,
        isError: Bool? = nil,
        parentToolCallId: String? = nil,
        assistantMessageToolCall: ToolCall? = nil,
        aborted: Bool? = nil,
        durationMs: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.type = type
        self.message = message
        self.assistantMessageEvent = assistantMessageEvent
        self.assistantMessageContentIndex = assistantMessageContentIndex
        self.assistantMessageDelta = assistantMessageDelta
        self.usage = usage
        self.assistantMessageToolCallId = assistantMessageToolCallId
        self.assistantMessageToolName = assistantMessageToolName
        self.messages = messages
        self.toolResults = toolResults
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.args = args
        self.partialResult = partialResult
        self.result = result
        self.isError = isError
        self.parentToolCallId = parentToolCallId
        self.assistantMessageToolCall = assistantMessageToolCall
        self.aborted = aborted
        self.durationMs = durationMs
        self.errorMessage = errorMessage
    }
}

public enum RpcEvent: Sendable {
    case agent(RpcAgentEvent)
    case hookUI(RpcHookUIRequest)
    case hookError(RpcHookError)
    case unknown([String: AnyCodable])
}

public struct RpcClientError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }

    public init(_ message: String) {
        self.message = message
    }
}

public typealias RpcEventListener = @Sendable (RpcEvent) -> Void

private struct RpcResponsePayload: Sendable {
    let id: String?
    let command: String
    let success: Bool
    let data: AnyCodable?
    let error: String?
    let orderedData: OrderedJSON?
}

private struct EventCollector {
    var events: [RpcAgentEvent]
    var continuation: CheckedContinuation<[RpcAgentEvent], Error>
}

public actor RpcClient {
    private let options: RpcClientOptions
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<RpcResponsePayload, Error>] = [:]
    private var listeners: [UUID: RpcEventListener] = [:]
    private var collectors: [UUID: EventCollector] = [:]
    private var requestId = 0
    private var stderrBuffer = ""
    private var exitError: RpcClientError?

    public init(options: RpcClientOptions = RpcClientOptions()) {
        self.options = options
    }

    public func start() async throws {
        guard process == nil else {
            throw RpcClientError("RPC client already started")
        }
        exitError = nil

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var args = ["--mode", "rpc"]
        if let provider = options.provider {
            args.append(contentsOf: ["--provider", provider])
        }
        if let model = options.model {
            args.append(contentsOf: ["--model", model])
        }
        args.append(contentsOf: options.args)

        if let cliPath = options.cliPath {
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["pi-coding-agent"] + args
        }

        if let cwd = options.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var environment = ProcessInfo.processInfo.environment
        if let extraEnv = options.env {
            for (key, value) in extraEnv {
                environment[key] = value
            }
        }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            Task { await self?.handleProcessExit(process) }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        stdoutTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    await self.handleLine(line)
                }
            } catch {
                await self.appendStderr("stdout error: \(error)")
            }
        }

        stderrTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    await self.appendStderr(line + "\n")
                }
            } catch {
                await self.appendStderr("stderr error: \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        if process.isRunning == false {
            let error = makeProcessExitError(process)
            exitError = error
            throw error
        }
    }

    public func stop() async {
        guard let process else { return }

        stdinPipe?.fileHandleForWriting.closeFile()
        process.terminate()
        await waitForExit(process)

        stdoutTask?.cancel()
        stderrTask?.cancel()

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RpcClientError("RPC client stopped"))
        }
        pendingRequests.removeAll()

        for (_, collector) in collectors {
            collector.continuation.resume(throwing: RpcClientError("RPC client stopped"))
        }
        collectors.removeAll()

        listeners.removeAll()

        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
    }

    public func onEvent(_ listener: @escaping RpcEventListener) -> @Sendable () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            Task { await self?.removeListener(id) }
        }
    }

    public func getStderr() -> String {
        stderrBuffer
    }

    @discardableResult
    public func prompt(_ message: String, images: [ImageContent]? = nil, streamingBehavior: HookInputStreamingBehavior? = nil) async throws -> PromptDisposition {
        var payload: [String: Any] = ["type": "prompt", "message": message]
        if let images {
            payload["images"] = images.map { ["data": $0.data, "mimeType": $0.mimeType] }
        }
        if let streamingBehavior { payload["streamingBehavior"] = streamingBehavior.rawValue }
        let response = try await send(payload)
        guard let data = try responseData(response) as? [String: Any],
              let raw = data["disposition"] as? String, let disposition = PromptDisposition(rawValue: raw) else {
            throw RpcClientError("Invalid prompt response")
        }
        return disposition
    }

    @discardableResult
    public func steer(_ message: String, images: [ImageContent]? = nil) async throws -> QueuedInputDisposition {
        try await queueInput(type: "steer", message: message, images: images)
    }

    @discardableResult
    public func followUp(_ message: String, images: [ImageContent]? = nil) async throws -> QueuedInputDisposition {
        try await queueInput(type: "follow_up", message: message, images: images)
    }

    private func queueInput(type: String, message: String, images: [ImageContent]?) async throws -> QueuedInputDisposition {
        var payload: [String: Any] = ["type": type, "message": message]
        if let images { payload["images"] = images.map { ["data": $0.data, "mimeType": $0.mimeType] } }
        let response = try await send(payload)
        guard let data = try responseData(response) as? [String: Any],
              let raw = data["disposition"] as? String, let disposition = QueuedInputDisposition(rawValue: raw) else {
            throw RpcClientError("Invalid \(type) response")
        }
        return disposition
    }

    public func abort() async throws {
        _ = try await send(["type": "abort"])
    }

    public func clearQueue() async throws -> (steering: [String], followUp: [String]) {
        let response = try await send(["type": "clear_queue"])
        guard let data = try responseData(response) as? [String: Any],
              let steering = data["steering"] as? [String],
              let followUp = data["followUp"] as? [String] else {
            throw RpcClientError("Invalid clear_queue response")
        }
        return (steering, followUp)
    }

    public func newSession(parentSession: String? = nil) async throws -> Bool {
        var payload: [String: Any] = ["type": "new_session"]
        if let parentSession { payload["parentSession"] = parentSession }
        let response = try await send(payload)
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid new_session response")
        }
        return data["cancelled"] as? Bool ?? false
    }

    public func getState() async throws -> RpcSessionState {
        let response = try await send(["type": "get_state"])
        guard let data = try responseData(response) as? [String: Any],
              let state = decodeRpcSessionState(data) else {
            throw RpcClientError("Invalid get_state response")
        }
        return state
    }

    public func setSessionName(_ name: String) async throws {
        _ = try await send(["type": "set_session_name", "name": name])
    }

    public func setModel(provider: String, modelId: String) async throws -> Model {
        let response = try await send(["type": "set_model", "provider": provider, "modelId": modelId])
        guard let data = try responseData(response) as? [String: Any],
              let model = decodeModel(data) else {
            throw RpcClientError("Invalid set_model response")
        }
        return model
    }

    public func cycleModel() async throws -> RpcCycleModelResult? {
        let response = try await send(["type": "cycle_model"])
        let data = try responseData(response)
        if data is NSNull { return nil }
        guard let dict = data as? [String: Any],
              let modelDict = dict["model"] as? [String: Any],
              let model = decodeModel(modelDict) else {
            throw RpcClientError("Invalid cycle_model response")
        }
        let thinking = ThinkingLevel(rawValue: dict["thinkingLevel"] as? String ?? "off") ?? .off
        let isScoped = dict["isScoped"] as? Bool ?? false
        return RpcCycleModelResult(model: model, thinkingLevel: thinking, isScoped: isScoped)
    }

    public func getAvailableModels() async throws -> [Model] {
        let response = try await send(["type": "get_available_models"])
        guard let data = try responseData(response) as? [String: Any],
              let models = data["models"] as? [[String: Any]] else {
            throw RpcClientError("Invalid get_available_models response")
        }
        return models.compactMap { decodeModel($0) }
    }

    public func setThinkingLevel(_ level: ThinkingLevel) async throws {
        _ = try await send(["type": "set_thinking_level", "level": level.rawValue])
    }

    public func cycleThinkingLevel() async throws -> ThinkingLevel? {
        let response = try await send(["type": "cycle_thinking_level"])
        let data = try responseData(response)
        if data is NSNull { return nil }
        guard let dict = data as? [String: Any],
              let raw = dict["level"] as? String else {
            throw RpcClientError("Invalid cycle_thinking_level response")
        }
        return ThinkingLevel(rawValue: raw)
    }

    public func setSteeringMode(_ mode: AgentSteeringMode) async throws {
        _ = try await send(["type": "set_steering_mode", "mode": mode.rawValue])
    }

    public func setFollowUpMode(_ mode: AgentFollowUpMode) async throws {
        _ = try await send(["type": "set_follow_up_mode", "mode": mode.rawValue])
    }

    public func compact(customInstructions: String? = nil) async throws -> CompactionResult {
        var payload: [String: Any] = ["type": "compact"]
        if let customInstructions { payload["customInstructions"] = customInstructions }
        let response = try await send(payload)
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid compact response")
        }
        return decodeCompactionResult(data)
    }

    public func setAutoCompaction(enabled: Bool) async throws {
        _ = try await send(["type": "set_auto_compaction", "enabled": enabled])
    }

    public func setAutoRetry(enabled: Bool) async throws {
        _ = try await send(["type": "set_auto_retry", "enabled": enabled])
    }

    public func abortRetry() async throws {
        _ = try await send(["type": "abort_retry"])
    }

    public func bash(_ command: String) async throws -> BashResult {
        let response = try await send(["type": "bash", "command": command])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid bash response")
        }
        return decodeBashResult(data)
    }

    public func abortBash() async throws {
        _ = try await send(["type": "abort_bash"])
    }

    public func getSessionStats() async throws -> SessionStats {
        let response = try await send(["type": "get_session_stats"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid get_session_stats response")
        }
        return decodeSessionStats(data)
    }

    public func exportHtml(outputPath: String? = nil) async throws -> String {
        var payload: [String: Any] = ["type": "export_html"]
        if let outputPath { payload["outputPath"] = outputPath }
        let response = try await send(payload)
        guard let data = try responseData(response) as? [String: Any],
              let path = data["path"] as? String else {
            throw RpcClientError("Invalid export_html response")
        }
        return path
    }

    public func switchSession(_ sessionPath: String) async throws -> Bool {
        let response = try await send(["type": "switch_session", "sessionPath": sessionPath])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid switch_session response")
        }
        return data["cancelled"] as? Bool ?? false
    }

    public func fork(entryId: String) async throws -> RpcForkResult {
        let response = try await send(["type": "fork", "entryId": entryId])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid fork response")
        }
        let text = data["text"] as? String ?? ""
        let cancelled = data["cancelled"] as? Bool ?? false
        return RpcForkResult(text: text, cancelled: cancelled)
    }

    public func getForkMessages() async throws -> [ForkableMessage] {
        let response = try await send(["type": "get_fork_messages"])
        guard let data = try responseData(response) as? [String: Any],
              let messages = data["messages"] as? [[String: Any]] else {
            throw RpcClientError("Invalid get_fork_messages response")
        }
        return messages.map {
            ForkableMessage(entryId: $0["entryId"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
    }

    public func getLastAssistantText() async throws -> String? {
        let response = try await send(["type": "get_last_assistant_text"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcClientError("Invalid get_last_assistant_text response")
        }
        if data["text"] is NSNull { return nil }
        return data["text"] as? String
    }

    public func getMessages() async throws -> [AgentMessage] {
        let response = try await send(["type": "get_messages"])
        guard let data = try responseData(response) as? [String: Any],
              let messages = data["messages"] as? [[String: Any]] else {
            throw RpcClientError("Invalid get_messages response")
        }
        return decodeRpcMessages(messages, ordered: response.orderedData?["messages"])
    }

    public func getCommands() async throws -> [RpcSlashCommand] {
        let response = try await send(["type": "get_commands"])
        guard let data = try responseData(response) as? [String: Any],
              let commands = data["commands"] as? [[String: Any]] else {
            throw RpcClientError("Invalid get_commands response")
        }
        return commands.compactMap { decodeRpcSlashCommand($0) }
    }

    public func sendHookUIResponse(_ response: RpcHookUIResponse) async throws {
        try sendRaw(response.payload)
    }

    public func waitForIdle(timeout: TimeInterval = 60) async throws {
        _ = try await collectEvents(timeout: timeout)
    }

    public func collectEvents(timeout: TimeInterval = 60) async throws -> [RpcAgentEvent] {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            collectors[id] = EventCollector(events: [], continuation: continuation)
            Task.detached { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.timeoutCollector(id)
            }
        }
    }

    public func promptAndWait(_ message: String, images: [ImageContent]? = nil, timeout: TimeInterval = 60) async throws -> [RpcAgentEvent] {
        async let events = collectEvents(timeout: timeout)
        try await prompt(message, images: images)
        return try await events
    }

    private func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func handleLine(_ line: String) async {
        guard let decoded = decodeRpcLine(line) else {
            return
        }

        let dict = decoded.object
        let ordered = decoded.ordered
        if (dict["type"] as? String) == "response" {
            let payload = RpcResponsePayload(
                id: dict["id"] as? String,
                command: dict["command"] as? String ?? "",
                success: dict["success"] as? Bool ?? false,
                data: dict["data"].map { AnyCodable($0) },
                error: dict["error"] as? String,
                orderedData: ordered?["data"]
            )
            if let id = payload.id, let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: payload)
            }
            return
        }

        let event = decodeRpcEvent(dict, ordered: ordered)
        dispatchEvent(event)
    }

    private func dispatchEvent(_ event: RpcEvent) {
        if case .agent(let agentEvent) = event {
            for (id, collector) in collectors {
                var updated = collector
                updated.events.append(agentEvent)
                collectors[id] = updated
                if agentEvent.type == "agent_settled" {
                    collectors.removeValue(forKey: id)
                    updated.continuation.resume(returning: updated.events)
                }
            }
        }

        let snapshot = Array(listeners.values)
        for listener in snapshot {
            Task { listener(event) }
        }
    }

    private func appendStderr(_ text: String) {
        stderrBuffer += text
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func handleProcessExit(_ process: Process) async {
        guard self.process === process else { return }
        // Drain the stdout reader before applying the process-exit fallback. The reader's
        // `bytes.lines` sequence completes on the pipe's EOF once the child exits, so this
        // deterministically processes any final buffered lines — including a terminal
        // `agent_settled` — instead of racing a fixed sleep.
        await stdoutTask?.value
        let error = exitError ?? makeProcessExitError(process)
        exitError = error
        rejectPendingRequests(error)
    }

    private func rejectPendingRequests(_ error: RpcClientError) {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()

        for (_, collector) in collectors {
            collector.continuation.resume(throwing: error)
        }
        collectors.removeAll()
    }

    private func timeoutRequest(_ id: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: RpcClientError("Timeout waiting for response. Stderr: \(stderrBuffer)"))
    }

    private func timeoutCollector(_ id: UUID) {
        guard let collector = collectors.removeValue(forKey: id) else { return }
        collector.continuation.resume(throwing: RpcClientError("Timeout waiting for agent_settled. Stderr: \(stderrBuffer)"))
    }

    private func send(_ command: [String: Any], timeout: TimeInterval = 30) async throws -> RpcResponsePayload {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw RpcClientError("RPC client not started")
        }
        if let exitError {
            throw exitError
        }
        guard process?.isRunning == true else {
            let error = process.map { makeProcessExitError($0) } ?? RpcClientError("RPC client not started")
            exitError = error
            throw error
        }
        requestId += 1
        let id = "req_\(requestId)"
        var payload = command
        payload["id"] = id

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try stdin.write(contentsOf: data)
        try stdin.write(contentsOf: Data([0x0A]))

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task.detached { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.timeoutRequest(id)
            }
        }
    }

    private func sendRaw(_ command: [String: Any]) throws {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw RpcClientError("RPC client not started")
        }
        let data = try JSONSerialization.data(withJSONObject: command, options: [])
        try stdin.write(contentsOf: data)
        try stdin.write(contentsOf: Data([0x0A]))
    }

    private func responseData(_ response: RpcResponsePayload) throws -> Any? {
        if response.success == false {
            let message = response.error ?? "Unknown error"
            throw RpcClientError("RPC error: \(message). Stderr: \(stderrBuffer)")
        }
        return response.data?.value
    }

    private func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func makeProcessExitError(_ process: Process) -> RpcClientError {
        let reason: String
        switch process.terminationReason {
        case .exit:
            reason = "exit code \(process.terminationStatus)"
        case .uncaughtSignal:
            reason = "signal \(process.terminationStatus)"
        @unknown default:
            reason = "status \(process.terminationStatus)"
        }
        return RpcClientError("RPC process exited with \(reason). Stderr: \(stderrBuffer)")
    }
}

/// Parse order only for lines that contain tool arguments.
func decodeRpcLine(_ line: String) -> (object: [String: Any], ordered: OrderedJSON?)? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let responseData = object["type"] as? String == "response" ? object["data"] as? [String: Any] : nil
    let carriesArguments = jsonObjectCarriesToolArguments(object)
        || responseData.map(jsonObjectCarriesToolArguments) == true
    let ordered = carriesArguments ? try? OrderedJSON.parse(line, allowDuplicateKeys: true) : nil
    return (object, ordered)
}

private func decodeRpcEvent(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> RpcEvent {
    if let type = dict["type"] as? String, type == "hook_ui_request" {
        if let request = decodeHookUIRequest(dict) {
            return .hookUI(request)
        }
    }
    if let type = dict["type"] as? String, type == "hook_error" {
        let hookPath = dict["hookPath"] as? String ?? ""
        let event = dict["event"] as? String ?? ""
        let error = dict["error"] as? String ?? ""
        let stack = dict["stack"] as? String
        return .hookError(RpcHookError(hookPath: hookPath, event: event, error: error, stack: stack))
    }
    if let event = decodeAgentEvent(dict, ordered: ordered) {
        return .agent(event)
    }
    return .unknown(dict.mapValues { AnyCodable($0) })
}

private func decodeHookUIRequest(_ dict: [String: Any]) -> RpcHookUIRequest? {
    guard let id = dict["id"] as? String,
          let method = dict["method"] as? String else {
        return nil
    }
    switch method {
    case "select":
        let title = dict["title"] as? String ?? ""
        let options = dict["options"] as? [String] ?? []
        return .select(id: id, title: title, options: options)
    case "confirm":
        let title = dict["title"] as? String ?? ""
        let message = dict["message"] as? String ?? ""
        return .confirm(id: id, title: title, message: message)
    case "input":
        let title = dict["title"] as? String ?? ""
        let placeholder = dict["placeholder"] as? String
        return .input(id: id, title: title, placeholder: placeholder)
    case "editor":
        let title = dict["title"] as? String ?? ""
        let prefill = dict["prefill"] as? String
        return .editor(id: id, title: title, prefill: prefill)
    case "notify":
        let message = dict["message"] as? String ?? ""
        let rawType = dict["notifyType"] as? String
        let notifyType = rawType.flatMap { HookNotificationType(rawValue: $0) }
        return .notify(id: id, message: message, notifyType: notifyType)
    case "setStatus":
        let key = dict["statusKey"] as? String ?? ""
        let text = dict["statusText"] as? String
        return .setStatus(id: id, statusKey: key, statusText: text)
    case "setWidget":
        let key = dict["widgetKey"] as? String ?? ""
        let lines = dict["widgetLines"] as? [String]
        return .setWidget(id: id, widgetKey: key, widgetLines: lines)
    case "setTitle":
        let title = dict["title"] as? String ?? ""
        return .setTitle(id: id, title: title)
    case "set_editor_text":
        let text = dict["text"] as? String ?? ""
        return .setEditorText(id: id, text: text)
    default:
        return nil
    }
}

func decodeAgentEvent(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> RpcAgentEvent? {
    guard let type = dict["type"] as? String else { return nil }
    switch type {
    case "agent_settled":
        return RpcAgentEvent(type: type, aborted: dict["aborted"] as? Bool)
    case "auto_compaction_end":
        return RpcAgentEvent(type: type, errorMessage: dict["errorMessage"] as? String)
    case "agent_start", "turn_start", "auto_compaction_start", "auto_retry_start", "auto_retry_end":
        return RpcAgentEvent(type: type)
    case "agent_end":
        let messages = (dict["messages"] as? [[String: Any]] ?? []).enumerated().compactMap { index, message in
            decodeAgentMessage(message, ordered: ordered?["messages"]?[index])
        }
        return RpcAgentEvent(type: type, messages: messages)
    case "turn_end":
        let messageDict = dict["message"] as? [String: Any]
        let message = messageDict.flatMap { decodeAgentMessage($0, ordered: ordered?["message"]) }
        let toolResults = (dict["toolResults"] as? [[String: Any]] ?? []).enumerated().compactMap { index, result in
            decodeToolResultMessage(result, ordered: ordered?["toolResults"]?[index])
        }
        return RpcAgentEvent(type: type, message: message, toolResults: toolResults)
    case "message_start":
        let messageDict = dict["message"] as? [String: Any]
        let message = messageDict.flatMap { decodeAgentMessage($0, ordered: ordered?["message"]) }
        return RpcAgentEvent(type: type, message: message)
    case "message_update":
        let messageDict = dict["message"] as? [String: Any]
        let message = messageDict.flatMap { decodeAgentMessage($0, ordered: ordered?["message"]) }
        // v0.84.1 (#7290): `message_update` no longer carries a cumulative `message` snapshot.
        // `assistantMessageEvent` is now an object; clients assemble deltas between
        // `message_start` and `message_end`, and `message_end` remains authoritative.
        let eventObject = dict["assistantMessageEvent"] as? [String: Any]
        let toolCall: ToolCall? = (eventObject?["toolCall"] as? [String: Any]).flatMap { block in
            guard case .toolCall(let call) = contentBlockFromJSONObject(
                block, ordered: ordered?["assistantMessageEvent"]?["toolCall"]
            ) else { return nil }
            return call
        }
        return RpcAgentEvent(
            type: type,
            message: message,
            assistantMessageEvent: eventObject?["type"] as? String,
            assistantMessageContentIndex: eventObject?["contentIndex"] as? Int,
            assistantMessageDelta: eventObject?["delta"] as? String,
            usage: (dict["usage"] as? [String: Any]).map(decodeUsage),
            assistantMessageToolCallId: toolCall?.id ?? eventObject?["id"] as? String,
            assistantMessageToolName: toolCall?.name ?? eventObject?["toolName"] as? String,
            toolCallId: toolCall?.id ?? eventObject?["id"] as? String,
            toolName: toolCall?.name ?? eventObject?["toolName"] as? String,
            args: toolCall?.arguments,
            assistantMessageToolCall: toolCall
        )
    case "message_end":
        let messageDict = dict["message"] as? [String: Any]
        let message = messageDict.flatMap { decodeAgentMessage($0, ordered: ordered?["message"]) }
        return RpcAgentEvent(type: type, message: message)
    case "tool_execution_start":
        let toolCallId = dict["toolCallId"] as? String ?? ""
        let toolName = dict["toolName"] as? String ?? ""
        let args = toolArgumentsWithOrder(
            (dict["args"] as? [String: Any] ?? [:]).mapValues { AnyCodable($0) },
            argumentsJSON: ordered?["args"].flatMap { toolArgumentsSource($0) }
        )
        return RpcAgentEvent(type: type, toolCallId: toolCallId, toolName: toolName, args: args, parentToolCallId: dict["parentToolCallId"] as? String)
    case "tool_execution_update":
        let toolCallId = dict["toolCallId"] as? String ?? ""
        let toolName = dict["toolName"] as? String ?? ""
        let args = toolArgumentsWithOrder(
            (dict["args"] as? [String: Any] ?? [:]).mapValues { AnyCodable($0) },
            argumentsJSON: ordered?["args"].flatMap { toolArgumentsSource($0) }
        )
        let partial = (dict["partialResult"] as? [String: Any]).map { decodeAgentToolResult($0, ordered: ordered?["partialResult"]) }
        return RpcAgentEvent(type: type, toolCallId: toolCallId, toolName: toolName, args: args, partialResult: partial, parentToolCallId: dict["parentToolCallId"] as? String)
    case "tool_execution_end":
        let toolCallId = dict["toolCallId"] as? String ?? ""
        let toolName = dict["toolName"] as? String ?? ""
        let result = (dict["result"] as? [String: Any]).map { decodeAgentToolResult($0, ordered: ordered?["result"]) }
        let isError = dict["isError"] as? Bool ?? false
        return RpcAgentEvent(type: type, toolCallId: toolCallId, toolName: toolName, result: result, isError: isError, parentToolCallId: dict["parentToolCallId"] as? String, durationMs: dict["durationMs"] as? Int)
    default:
        return nil
    }
}

func decodeRpcMessages(_ messages: [[String: Any]], ordered: OrderedJSON?) -> [AgentMessage] {
    messages.enumerated().compactMap { index, message in
        decodeAgentMessage(message, ordered: ordered?[index])
    }
}

private func decodeAgentMessage(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> AgentMessage? {
    guard let role = dict["role"] as? String else { return nil }
    switch role {
    case "user":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let contentValue = dict["content"]
        let content: UserContent
        if let text = contentValue as? String {
            content = .text(text)
        } else if let blocks = contentValue as? [Any] {
            let contentBlocks = blocks.enumerated().compactMap { index, block -> ContentBlock? in
                guard let dict = block as? [String: Any] else { return nil }
                return contentBlockFromJSONObject(dict, ordered: ordered?["content"]?[index])
            }
            content = .blocks(contentBlocks)
        } else {
            content = .text("")
        }
        return .user(UserMessage(content: content, timestamp: timestamp))
    case "assistant":
        var assistant = assistantMessageFromJSONObject(dict, ordered: ordered)
        if dict["timestamp"] == nil { assistant.timestamp = Int64(Date().timeIntervalSince1970 * 1000) }
        return .assistant(assistant)
    case "toolResult":
        return decodeToolResultMessage(dict, ordered: ordered).map { .toolResult($0) }
    case "bashExecution", "hookMessage", "branchSummary", "compactionSummary":
        let payload = dict
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        return .custom(AgentCustomMessage(role: role, payload: AnyCodable(payload), timestamp: timestamp))
    default:
        return nil
    }
}

private func decodeToolResultMessage(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> ToolResultMessage? {
    let toolCallId = dict["toolCallId"] as? String ?? ""
    let toolName = dict["toolName"] as? String ?? ""
    let isError = dict["isError"] as? Bool ?? false
    let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
    let details = dict["details"].map { AnyCodable($0) }
    let contentBlocks = (dict["content"] as? [Any] ?? []).enumerated().compactMap { index, block -> ContentBlock? in
        guard let dict = block as? [String: Any] else { return nil }
        return contentBlockFromJSONObject(dict, ordered: ordered?["content"]?[index])
    }
    return ToolResultMessage(
        toolCallId: toolCallId,
        toolName: toolName,
        content: contentBlocks,
        details: details,
        usage: (dict["usage"] as? [String: Any]).map(decodeUsage),
        nestedCalls: (dict["nestedCalls"] as? [String: Any]).flatMap {
            nestedToolCallsFromJSONObject($0, ordered: ordered?["nestedCalls"])
        },
        isError: isError,
        timestamp: timestamp,
        durationMs: dict["durationMs"] as? Int
    )
}

private func decodeAgentToolResult(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> AgentToolResult {
    let details = dict["details"].map { AnyCodable($0) }
    let contentBlocks = (dict["content"] as? [Any] ?? []).enumerated().compactMap { index, block -> ContentBlock? in
        guard let dict = block as? [String: Any] else { return nil }
        return contentBlockFromJSONObject(dict, ordered: ordered?["content"]?[index])
    }
    var result = AgentToolResult(content: contentBlocks, details: details)
    result.structuredContent = dict["structuredContent"].map { AnyCodable($0) }
    result.isError = dict["isError"] as? Bool
    result.usage = (dict["usage"] as? [String: Any]).map(decodeUsage)
    return result
}

private func decodeUsage(_ dict: [String: Any]) -> Usage {
    let input = dict["input"] as? Int ?? 0
    let output = dict["output"] as? Int ?? 0
    let cacheRead = dict["cacheRead"] as? Int ?? 0
    let cacheWrite = dict["cacheWrite"] as? Int ?? 0
    let totalTokens = dict["totalTokens"] as? Int ?? (input + output + cacheRead + cacheWrite)
    var usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: totalTokens)
    if let cost = dict["cost"] as? [String: Any] {
        usage.cost.input = cost["input"] as? Double ?? 0
        usage.cost.output = cost["output"] as? Double ?? 0
        usage.cost.cacheRead = cost["cacheRead"] as? Double ?? 0
        usage.cost.cacheWrite = cost["cacheWrite"] as? Double ?? 0
        usage.cost.total = cost["total"] as? Double ?? 0
    }
    return usage
}

private func decodeModel(_ dict: [String: Any]) -> Model? {
    guard let id = dict["id"] as? String else { return nil }
    let name = dict["name"] as? String ?? id
    let api = Api(rawValue: dict["api"] as? String ?? "") ?? .openAIResponses
    let provider = dict["provider"] as? String ?? ""
    let baseUrl = dict["baseUrl"] as? String ?? ""
    let reasoning = dict["reasoning"] as? Bool ?? false
    let input = (dict["input"] as? [String] ?? []).compactMap { ModelInput(rawValue: $0) }
    let costDict = dict["cost"] as? [String: Any] ?? [:]
    let cost = ModelCost(
        input: costDict["input"] as? Double ?? 0,
        output: costDict["output"] as? Double ?? 0,
        cacheRead: costDict["cacheRead"] as? Double ?? 0,
        cacheWrite: costDict["cacheWrite"] as? Double ?? 0
    )
    let contextWindow = dict["contextWindow"] as? Int ?? 0
    let maxTokens = dict["maxTokens"] as? Int ?? 0
    let headers = dict["headers"] as? [String: String]
    let compat = (dict["compat"] as? [String: Any]).map { decodeCompat($0) }
    return Model(
        id: id,
        name: name,
        api: api,
        provider: provider,
        baseUrl: baseUrl,
        reasoning: reasoning,
        input: input,
        cost: cost,
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        headers: headers,
        compat: compat
    )
}

private func decodeCompat(_ dict: [String: Any]) -> OpenAICompat {
    let maxTokensField = (dict["maxTokensField"] as? String).flatMap { OpenAICompatMaxTokensField(rawValue: $0) }
    return OpenAICompat(
        supportsStore: dict["supportsStore"] as? Bool,
        supportsDeveloperRole: dict["supportsDeveloperRole"] as? Bool,
        supportsReasoningEffort: dict["supportsReasoningEffort"] as? Bool,
        maxTokensField: maxTokensField,
        requiresToolResultName: dict["requiresToolResultName"] as? Bool,
        requiresAssistantAfterToolResult: dict["requiresAssistantAfterToolResult"] as? Bool,
        requiresThinkingAsText: dict["requiresThinkingAsText"] as? Bool,
        requiresMistralToolIds: dict["requiresMistralToolIds"] as? Bool
    )
}

private func decodeRpcSessionState(_ dict: [String: Any]) -> RpcSessionState? {
    let model = (dict["model"] as? [String: Any]).flatMap { decodeModel($0) }
    let thinking = ThinkingLevel(rawValue: dict["thinkingLevel"] as? String ?? "off") ?? .off
    let isStreaming = dict["isStreaming"] as? Bool ?? false
    let isCompacting = dict["isCompacting"] as? Bool ?? false
    let steeringMode = AgentSteeringMode(rawValue: dict["steeringMode"] as? String ?? "all") ?? .all
    let followUpMode = AgentFollowUpMode(rawValue: dict["followUpMode"] as? String ?? "one-at-a-time") ?? .oneAtATime
    guard let sessionId = dict["sessionId"] as? String else { return nil }
    let autoCompactionEnabled = dict["autoCompactionEnabled"] as? Bool ?? true
    let messageCount = dict["messageCount"] as? Int ?? 0
    let pendingMessageCount = dict["pendingMessageCount"] as? Int ?? 0
    let sessionFile = dict["sessionFile"] as? String
    let sessionName = dict["sessionName"] as? String
    return RpcSessionState(
        model: model,
        thinkingLevel: thinking,
        isStreaming: isStreaming,
        isCompacting: isCompacting,
        steeringMode: steeringMode,
        followUpMode: followUpMode,
        sessionFile: sessionFile,
        sessionId: sessionId,
        sessionName: sessionName,
        autoCompactionEnabled: autoCompactionEnabled,
        messageCount: messageCount,
        pendingMessageCount: pendingMessageCount
    )
}

private func decodeRpcSlashCommand(_ dict: [String: Any]) -> RpcSlashCommand? {
    guard let name = dict["name"] as? String,
          let source = dict["source"] as? String else {
        return nil
    }
    let description = dict["description"] as? String
    let location = dict["location"] as? String
    let path = dict["path"] as? String
    return RpcSlashCommand(
        name: name,
        description: description,
        source: source,
        location: location,
        path: path
    )
}

private func decodeCompactionResult(_ dict: [String: Any]) -> CompactionResult {
    let summary = dict["summary"] as? String ?? ""
    let firstKeptEntryId = dict["firstKeptEntryId"] as? String ?? ""
    let tokensBefore = dict["tokensBefore"] as? Int ?? 0
    let details = dict["details"].map { AnyCodable($0) }
    return CompactionResult(summary: summary, firstKeptEntryId: firstKeptEntryId, tokensBefore: tokensBefore, details: details)
}

private func decodeBashResult(_ dict: [String: Any]) -> BashResult {
    let output = dict["output"] as? String ?? ""
    let exitCode = dict["exitCode"] as? Int
    let cancelled = dict["cancelled"] as? Bool ?? false
    let truncated = dict["truncated"] as? Bool ?? false
    let fullOutputPath = dict["fullOutputPath"] as? String
    return BashResult(output: output, exitCode: exitCode, cancelled: cancelled, truncated: truncated, fullOutputPath: fullOutputPath)
}

private func decodeSessionStats(_ dict: [String: Any]) -> SessionStats {
    let tokensDict = dict["tokens"] as? [String: Any] ?? [:]
    let tokens = SessionStats.TokenStats(
        input: tokensDict["input"] as? Int ?? 0,
        output: tokensDict["output"] as? Int ?? 0,
        cacheRead: tokensDict["cacheRead"] as? Int ?? 0,
        cacheWrite: tokensDict["cacheWrite"] as? Int ?? 0,
        total: tokensDict["total"] as? Int ?? 0
    )
    let contextUsage: ContextUsage?
    if let usageDict = dict["contextUsage"] as? [String: Any] {
        let usageTokens = usageDict["tokens"] as? Int
        let contextWindow = usageDict["contextWindow"] as? Int ?? 0
        let percent: Double?
        if let value = usageDict["percent"] as? Double {
            percent = value
        } else if let value = usageDict["percent"] as? Int {
            percent = Double(value)
        } else {
            percent = nil
        }
        contextUsage = ContextUsage(tokens: usageTokens, contextWindow: contextWindow, percent: percent)
    } else {
        contextUsage = nil
    }
    return SessionStats(
        sessionFile: dict["sessionFile"] as? String,
        sessionId: dict["sessionId"] as? String ?? "",
        userMessages: dict["userMessages"] as? Int ?? 0,
        assistantMessages: dict["assistantMessages"] as? Int ?? 0,
        toolCalls: dict["toolCalls"] as? Int ?? 0,
        toolResults: dict["toolResults"] as? Int ?? 0,
        totalMessages: dict["totalMessages"] as? Int ?? 0,
        tokens: tokens,
        cost: dict["cost"] as? Double ?? 0,
        contextUsage: contextUsage
    )
}
