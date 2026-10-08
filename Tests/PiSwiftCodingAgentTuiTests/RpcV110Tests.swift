import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

private func v110DecodeEvent(_ payload: [String: Any]) throws -> RpcAgentEvent? {
    let data = try JSONSerialization.data(withJSONObject: payload)
    let line = String(decoding: data, as: UTF8.self)
    let decoded = try #require(decodeRpcLine(line))
    return decodeAgentEvent(decoded.object, ordered: decoded.ordered)
}

@Suite("RPC v1.1.0 fields")
struct RpcV110Tests {
    @Test(arguments: [false, true])
    func settledDecodesAbort(_ aborted: Bool) throws {
        let event = try #require(try v110DecodeEvent(encodeSessionEvent(.agentSettled(aborted: aborted))))
        #expect(event.type == "agent_settled")
        #expect(event.aborted == aborted)
    }

    @Test func toolEndDecodesDurationForMainAndNestedCalls() throws {
        for parent in [nil, "parent"] as [String?] {
            var payload: [String: Any] = [
                "type": "tool_execution_end", "toolCallId": "call", "toolName": "read",
                "result": ["content": [["type": "text", "text": "done"]]], "isError": false, "durationMs": 42,
            ]
            if let parent { payload["parentToolCallId"] = parent }
            let event = try #require(try v110DecodeEvent(payload))
            #expect(event.durationMs == 42)
            #expect(event.toolCallId == "call")
            #expect(event.parentToolCallId == parent)
            #expect(event.isError == false)
            #expect(event.result?.content.count == 1)
        }
        let encoded = encodeSessionEvent(.agent(.toolExecutionEnd(
            toolCallId: "call", toolName: "read", result: AgentToolResult(content: []), isError: false, durationMs: 0)))
        #expect(try v110DecodeEvent(encoded)?.durationMs == 0)
    }

    @Test func toolResultDurationAndUsageDecodeInMessagesAndTurns() throws {
        let usage = Usage(input: 12, output: 4, cacheRead: 3, cacheWrite: 2, totalTokens: 21,
            cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.03, cacheWrite: 0.02, total: 0.35))
        let result = ToolResultMessage(toolCallId: "call", toolName: "read", content: [.text(TextContent(text: "done"))],
            usage: usage, isError: false, timestamp: 123, durationMs: 17)
        let payload = encodeSessionEvent(.agent(.messageEnd(message: .toolResult(result))))
        let event = try #require(try v110DecodeEvent(payload))
        guard case .toolResult(let decoded) = event.message else {
            Issue.record("The tool result message is absent")
            return
        }
        checkResult(decoded)
        let raw = try #require(payload["message"] as? [String: Any])
        let messages = decodeRpcMessages([raw], ordered: nil)
        guard case .toolResult(let history) = messages.first else {
            Issue.record("The tool result history is absent")
            return
        }
        checkResult(history)
        let turn = try #require(try v110DecodeEvent(["type": "turn_end", "toolResults": [raw]]))
        checkResult(try #require(turn.toolResults?.first))
    }

    private func checkResult(_ result: ToolResultMessage) {
        #expect(result.durationMs == 17)
        #expect(result.timestamp == 123)
        #expect(result.usage?.input == 12)
        #expect(result.usage?.output == 4)
        #expect(result.usage?.cacheRead == 3)
        #expect(result.usage?.cacheWrite == 2)
        #expect(result.usage?.totalTokens == 21)
        #expect(result.usage?.cost.total == 0.35)
    }

    @Test func compactionDecodesErrorMessage() throws {
        let payload = encodeSessionEvent(.autoCompactionEnd(result: nil, aborted: false, willRetry: true,
            errorMessage: "Compaction failed"))
        let event = try #require(try v110DecodeEvent(payload))
        #expect(event.type == "auto_compaction_end")
        #expect(event.errorMessage == "Compaction failed")
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func bashHistoryKeepsExcludeFromContext(_ excluded: Bool?) throws {
        var payload: [String: Any] = ["role": "bashExecution", "command": "echo done", "output": "done",
            "exitCode": 0, "cancelled": false, "truncated": false, "timestamp": 123]
        if let excluded { payload["excludeFromContext"] = excluded }
        let data = try JSONSerialization.data(withJSONObject: ["messages": [payload]])
        let wire = try #require(decodeRpcLine(String(decoding: data, as: UTF8.self)))
        let raw = try #require(wire.object["messages"] as? [[String: Any]])
        let messages = decodeRpcMessages(raw, ordered: wire.ordered?["messages"])
        guard case .custom(let message) = messages.first else {
            Issue.record("The bash message is absent")
            return
        }
        let decoded = try #require(message.payload?.value as? [String: Any])
        #expect(decoded["excludeFromContext"] as? Bool == excluded)
        #expect(decoded["output"] as? String == "done")
    }

    @Test func oldPayloadsKeepOptionalFieldsAbsent() throws {
        let settled = try #require(try v110DecodeEvent(["type": "agent_settled"]))
        #expect(settled.aborted == nil)
        let compact = try #require(try v110DecodeEvent(["type": "auto_compaction_end"]))
        #expect(compact.errorMessage == nil)
        let end = try #require(try v110DecodeEvent(["type": "tool_execution_end", "toolCallId": "call", "toolName": "read",
            "result": ["content": []], "isError": false]))
        #expect(end.durationMs == nil)
        let event = try #require(try v110DecodeEvent(["type": "message_end", "message": [
            "role": "toolResult", "toolCallId": "call", "toolName": "read", "content": [], "isError": false,
        ]]))
        guard case .toolResult(let result) = event.message else {
            Issue.record("The old tool result is absent")
            return
        }
        #expect(result.durationMs == nil)
        #expect(result.usage == nil)
    }
}
