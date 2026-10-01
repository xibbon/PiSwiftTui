import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private let f3tArguments = #"{"z":{"z":1,"a":2,"10":10,"2":2},"a":0,"10":10,"2":2}"#

private func f3tCall() throws -> ToolCall {
    let values = try JSONSerialization.jsonObject(with: Data(f3tArguments.utf8)) as! [String: Any]
    return ToolCall(id: "call", name: "tool", arguments: values.mapValues(AnyCodable.init),
                    argumentsJSON: parseToolArgumentsSource(f3tArguments))
}

@MainActor @Suite(.serialized) struct F3TOrderedRenderersTests {
    @Test func capturedArgumentsKeepJavascriptOrderAtEveryLevel() throws {
        let call = try f3tCall()
        let text = toolTestPlain(formatToolCallWithArgs(call.name, args: call.arguments, theme: theme, expanded: false))
        #expect(text == #"tool 2=2 10=10 z={"2":2,"10":10,"z":1,"a":2} a=0"#)
        let expanded = toolTestPlain(formatToolCallWithArgs(call.name, args: call.arguments, theme: theme, expanded: true))
        #expect(expanded.hasPrefix("tool\n  2: 2\n  10: 10\n  z: {"))
        #expect(expanded.contains("\"10\": 10,\n      \"z\": 1,\n      \"a\": 2"))
    }

    @Test func unknownOrderUsesT3aFallback() throws {
        let call = try f3tCall()
        let values = call.arguments.mapValues { AnyCodable($0.value) }
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: values, theme: theme, expanded: false))
                == #"tool 2=2 10=10 a=0 z={"2":2,"10":10,"a":2,"z":1}"#)
    }

    @Test func storedOrderIsNotSortedAgainAndCurrentValuesWin() throws {
        var call = try f3tCall()
        call.arguments["1"] = AnyCodable(1)
        call.arguments["z"] = AnyCodable(["z": 9, "a": 8, "10": 10, "2": 2, "1": 1])
        let args = toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON)
        #expect(toolTestPlain(formatToolCallWithArgs("tool", args: args, theme: theme, expanded: false))
                == #"tool 2=2 10=10 z={"2":2,"10":10,"z":9,"a":8,"1":1} a=0 1=1"#)
    }

    @Test func mcpAndBothExecutionFallbacksKeepOrderOnUpdate() throws {
        let call = try f3tCall()
        let expected = #"tool 2=2 10=10 z={"2":2,"10":10,"z":1,"a":2} a=0"#
        let ui = TUI(terminal: ToolTestTerminal())
        let rows = [
            ToolExecutionComponent(toolName: "tool", args: [:], ui: ui),
            ToolExecutionComponent(toolName: "tool", args: [:], renderers: ToolRenderers(), ui: ui),
            ToolExecutionComponent(toolName: "tool", args: [:], renderers: createMcpRenderers(label: "tool"), ui: ui),
        ]
        for row in rows {
            row.updateArgs(call.arguments)
            #expect(toolTestText(row).contains(expected))
            row.setExpanded(true)
            #expect(toolTestText(row).contains("\"z\": 1,\n"))
        }
    }

    @Test func nestedRecordsRenderWithTheirCompanion() throws {
        let call = try f3tCall()
        // The record keeps its companion separately from its dictionary values.
        let nested = NestedToolCalls(calls: [NestedToolCallRecord(id: "nested", name: "child",
            arguments: call.arguments.mapValues { AnyCodable($0.value) }, status: .ok,
            argumentsJSON: call.argumentsJSON)], complete: true)
        for renderers in [nil, ToolRenderers(), createMcpRenderers(label: "parent")] {
            let row = ToolExecutionComponent(toolName: "parent", args: [:], renderers: renderers,
                                             ui: TUI(terminal: ToolTestTerminal()))
            row.updateResult(ToolResultMessage(toolCallId: "parent", toolName: "parent", content: [],
                                               nestedCalls: nested, isError: false))
            #expect(toolTestText(row).contains(#"child 2=2 10=10 z={"2":2,"10":10,"z":1,"a":2} a=0"#))
        }
    }
}

private func f3tEvent(_ line: String) throws -> RpcAgentEvent {
    let decoded = try #require(decodeRpcLine(line))
    return try #require(decodeAgentEvent(decoded.object, ordered: decoded.ordered))
}

@Suite struct F3TOrderedRpcTests {
    @Test func executionStartAndUpdateKeepRawOrderIncludingNestedEvents() throws {
        for type in ["tool_execution_start", "tool_execution_update"] {
            let event = try f3tEvent("{\"type\":\"\(type)\",\"toolCallId\":\"child\",\"parentToolCallId\":\"parent\",\"args\":\(f3tArguments)}")
            let args = try #require(event.args)
            #expect(orderedToolArguments(args).map(\.key) == ["2", "10", "z", "a"])
            #expect(toolArgumentsToOrderedJSON(args)["z"]?.objectEntries?.map(\.0) == ["2", "10", "z", "a"])
            #expect(event.parentToolCallId == "parent")
        }
    }

    @Test func assistantBlocksKeepOrderInEveryMessageEvent() throws {
        let message = "{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call\",\"name\":\"tool\",\"arguments\":\(f3tArguments)}]}"
        for type in ["message_start", "message_update", "message_end", "turn_end", "agent_end"] {
            let member = type == "agent_end" ? "\"messages\":[\(message)]" : "\"message\":\(message)"
            let event = try f3tEvent("{\"type\":\"\(type)\",\(member)}")
            let decodedMessage = try #require(event.message ?? event.messages?.first)
            guard case .assistant(let assistant) = decodedMessage,
                  case .toolCall(let call) = assistant.content.first else {
                Issue.record("Expected an assistant tool call")
                continue
            }
            #expect(orderedToolArguments(call).map(\.key) == ["2", "10", "z", "a"])
            #expect(toolArgumentsToOrderedJSON(call.arguments, argumentsJSON: call.argumentsJSON)["z"]?.objectEntries?.map(\.0) == ["2", "10", "z", "a"])
        }
    }

    @Test func finalToolCallBlockKeepsItsCompanion() throws {
        let event = try f3tEvent("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"tool_call_end\",\"toolCall\":{\"type\":\"toolCall\",\"id\":\"call\",\"name\":\"tool\",\"arguments\":\(f3tArguments)}}}")
        let call = try #require(event.assistantMessageToolCall)
        #expect(orderedToolArguments(call).map(\.key) == ["2", "10", "z", "a"])
        #expect(orderedToolArguments(try #require(event.args)).map(\.key) == ["2", "10", "z", "a"])
        #expect(event.toolCallId == "call")
    }

    @Test func nestedCallsDecodeInBothResultReaders() throws {
        let result = "{\"role\":\"toolResult\",\"toolCallId\":\"parent\",\"toolName\":\"parent\",\"content\":[],\"nestedCalls\":{\"complete\":true,\"calls\":[{\"id\":\"child\",\"name\":\"tool\",\"status\":\"ok\",\"arguments\":\(f3tArguments)}]}}"
        let event = try f3tEvent("{\"type\":\"turn_end\",\"message\":\(result),\"toolResults\":[\(result)]}")
        guard case .toolResult(let message) = event.message else {
            Issue.record("Expected a tool result")
            return
        }
        for nested in [message.nestedCalls, event.toolResults?.first?.nestedCalls] {
            let calls = try #require(nested)
            let call = try #require(calls.calls.first)
            #expect(calls.complete)
            #expect(orderedToolArguments(try #require(call.arguments), argumentsJSON: call.argumentsJSON).map(\.key) == ["2", "10", "z", "a"])
        }
    }

    @Test func rawParseIsSelectiveAndAllowsRepeatedKeys() throws {
        for line in [#"{"type":"agent_start"}"#, #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"plain"}]}}"#, #"{"type":"hook_error","details":{"type":"toolCall","arguments":{"z":0}}}"#] {
            #expect(try #require(decodeRpcLine(line)).ordered == nil)
        }
        let event = try f3tEvent(#"{"type":"tool_execution_start","args":{"z":1,"a":2,"z":3}}"#)
        #expect(orderedToolArguments(try #require(event.args)).map(\.key) == ["z", "a"])
    }

    @Test func messagesResponseWritesOneOrderedArgumentObject() throws {
        let call = try f3tCall()
        let message = AssistantMessage(content: [.toolCall(call)], api: .openAIResponses,
                                       provider: "test", model: "test", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
        let line = encodeRpcMessagesResponse("request", messages: [.assistant(message)])
        #expect(!line.contains("argumentsJSON"))
        #expect(line.components(separatedBy: "\"arguments\":").count == 2)
        let decoded = try #require(decodeRpcLine(line))
        #expect(decoded.ordered?["data"]?["messages"]?[0]?["content"]?[0]?["arguments"]?.objectEntries?.map(\.0) == ["2", "10", "z", "a"])
    }

    @Test func clientMessagesResponseDecoderKeepsOrder() throws {
        let call = try f3tCall()
        let message = AssistantMessage(content: [.toolCall(call)], api: .openAIResponses,
            provider: "test", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
        let decoded = try #require(decodeRpcLine(encodeRpcMessagesResponse("request", messages: [.assistant(message)])))
        let data = try #require(decoded.object["data"] as? [String: Any])
        let rawMessages = try #require(data["messages"] as? [[String: Any]])
        let messages = decodeRpcMessages(rawMessages, ordered: decoded.ordered?["data"]?["messages"])
        guard case .assistant(let assistant) = messages.first,
              case .toolCall(let result) = assistant.content.first else {
            Issue.record("Expected a tool call from get_messages")
            return
        }
        #expect(orderedToolArguments(result).map(\.key) == ["2", "10", "z", "a"])
        #expect(toolArgumentsToOrderedJSON(result.arguments, argumentsJSON: result.argumentsJSON)["z"]?.objectEntries?.map(\.0) == ["2", "10", "z", "a"])
    }
}
