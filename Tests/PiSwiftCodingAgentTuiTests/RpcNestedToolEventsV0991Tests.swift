import Foundation
import PiSwiftAI
import Testing
@testable import PiSwiftCodingAgentTui

// v0.99.0: nested tool calls (ctx.executeTool, codemode) emit tool_execution_* events with
// parentToolCallId, and tool results carry structuredContent, isError and usage.

@Test func rpcDecodesParentToolCallIdOnNestedToolEvents() throws {
    let start = try #require(decodeAgentEvent([
        "type": "tool_execution_start", "toolCallId": "call_1/0", "toolName": "read",
        "args": ["path": "a.txt"], "parentToolCallId": "call_1",
    ]))
    #expect(start.parentToolCallId == "call_1")

    let update = try #require(decodeAgentEvent([
        "type": "tool_execution_update", "toolCallId": "call_1/0", "toolName": "read",
        "args": [:], "partialResult": ["content": []], "parentToolCallId": "call_1",
    ]))
    #expect(update.parentToolCallId == "call_1")

    let end = try #require(decodeAgentEvent([
        "type": "tool_execution_end", "toolCallId": "call_1/0", "toolName": "read",
        "result": ["content": [], "structuredContent": ["exit_code": 2], "isError": true,
                   "usage": ["input": 3, "output": 4]],
        "isError": true, "parentToolCallId": "call_1",
    ]))
    #expect(end.parentToolCallId == "call_1")
    #expect(end.result?.isError == true)
    #expect(end.result?.structuredContent?.value as? [String: Int] == ["exit_code": 2])
    #expect(end.result?.usage?.output == 4)
}

@Test func rpcTopLevelToolEventsHaveNoParent() throws {
    let start = try #require(decodeAgentEvent([
        "type": "tool_execution_start", "toolCallId": "call_1", "toolName": "bash", "args": [:],
    ]))
    #expect(start.parentToolCallId == nil)
}
