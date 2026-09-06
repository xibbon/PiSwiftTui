import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// State shared by the call and result renderers of one tool row.
@MainActor
public final class ToolRenderState {
    public var values: [String: Any] = [:]
    public init() {}
}

@MainActor
public struct ToolRenderContext {
    public var args: [String: AnyCodable]
    public var toolCallId: String
    public var invalidate: () -> Void
    public var lastComponent: Component?
    public var state: ToolRenderState
    public var cwd: String
    public var executionStarted: Bool
    public var argsComplete: Bool
    public var isPartial: Bool
    public var expanded: Bool
    public var showImages: Bool
    public var isError: Bool

    public init(args: [String: AnyCodable] = [:], toolCallId: String = "", invalidate: @escaping () -> Void = {}, lastComponent: Component? = nil, state: ToolRenderState = ToolRenderState(), cwd: String = FileManager.default.currentDirectoryPath, executionStarted: Bool = false, argsComplete: Bool = false, isPartial: Bool = true, expanded: Bool = false, showImages: Bool = true, isError: Bool = false) {
        self.args = args
        self.toolCallId = toolCallId
        self.invalidate = invalidate
        self.lastComponent = lastComponent
        self.state = state
        self.cwd = cwd
        self.executionStarted = executionStarted
        self.argsComplete = argsComplete
        self.isPartial = isPartial
        self.expanded = expanded
        self.showImages = showImages
        self.isError = isError
    }
}

@MainActor
public struct ToolRenderers {
    public var renderShell: ToolRenderShell
    public var renderCall: (([String: AnyCodable], Theme, ToolRenderContext) throws -> Component)?
    public var renderResult: ((AgentToolResult, RenderResultOptions, Theme, ToolRenderContext) throws -> Component)?

    public init(renderShell: ToolRenderShell = .default, renderCall: (([String: AnyCodable], Theme, ToolRenderContext) throws -> Component)? = nil, renderResult: ((AgentToolResult, RenderResultOptions, Theme, ToolRenderContext) throws -> Component)? = nil) {
        self.renderShell = renderShell
        self.renderCall = renderCall
        self.renderResult = renderResult
    }
}
