import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Render session tool records with the same components as the TUI.
@MainActor
public final class TuiToolHtmlRenderer: ToolHtmlRenderer {
    private let themeProvider: () -> Theme
    private let cwd: String
    private let width: Int
    private let getRenderers: (String) -> ToolRenderers?
    private var arguments: [String: [String: AnyCodable]] = [:]
    private var callComponents: [String: Component] = [:]
    private var resultComponents: [String: Component] = [:]
    private var states: [String: ToolRenderState] = [:]

    public init(theme: Theme, cwd: String, width: Int = 100,
                getTheme: (() -> Theme)? = nil,
                getRenderers: @escaping (String) -> ToolRenderers?) {
        self.themeProvider = getTheme ?? { theme }
        self.cwd = cwd
        self.width = width
        self.getRenderers = getRenderers
    }

    private func context(_ id: String, last: Component?, expanded: Bool,
                         partial: Bool, error: Bool) -> ToolRenderContext {
        let state = states[id] ?? ToolRenderState()
        states[id] = state
        return ToolRenderContext(args: arguments[id] ?? [:], toolCallId: id,
            lastComponent: last, state: state, cwd: cwd, executionStarted: true,
            argsComplete: true, isPartial: partial, expanded: expanded,
            showImages: false, isError: error)
    }

    // These methods have no suspension point. Each component/state update is atomic
    // on the main actor, including when two exports use this adapter at the same time.
    public func renderCall(toolCallId: String, name: String, arguments: OrderedJSON) async -> String? {
        do {
            let values = try JSONSerialization.jsonObject(with: Data(arguments.serialized().utf8)) as? [String: Any] ?? [:]
            let args = toolArgumentsWithOrder(values.mapValues(AnyCodable.init), argumentsJSON: toolArgumentsSource(arguments))
            self.arguments[toolCallId] = args
            guard let render = getRenderers(name)?.renderCall else { return nil }
            let component = try render(args, themeProvider(), context(toolCallId,
                last: callComponents[toolCallId], expanded: false, partial: true, error: false))
            callComponents[toolCallId] = component
            return ansiLinesToHtml(component.render(width: width))
        } catch { return nil }
    }

    public func renderResult(toolCallId: String, name: String, result: [ContentBlock],
                             details: AnyCodable?, isError: Bool) async -> (collapsed: String?, expanded: String?)? {
        do {
            guard let render = getRenderers(name)?.renderResult else { return nil }
            let value = AgentToolResult(content: result, details: details, isError: isError)
            let theme = themeProvider()
            let collapsedComponent = try render(value, RenderResultOptions(expanded: false, isPartial: false), theme,
                context(toolCallId, last: resultComponents[toolCallId], expanded: false, partial: false, error: isError))
            resultComponents[toolCallId] = collapsedComponent
            let collapsed = ansiLinesToHtml(trimResultLines(collapsedComponent.render(width: width)))
            let expandedComponent = try render(value, RenderResultOptions(expanded: true, isPartial: false), theme,
                context(toolCallId, last: resultComponents[toolCallId], expanded: true, partial: false, error: isError))
            resultComponents[toolCallId] = expandedComponent
            let expanded = ansiLinesToHtml(trimResultLines(expandedComponent.render(width: width)))
            return (collapsed.isEmpty || collapsed == expanded ? nil : collapsed, expanded)
        } catch { return nil }
    }

    private func trimResultLines(_ lines: [String]) -> [String] {
        func blank(_ line: String) -> Bool {
            line.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var start = 0
        var end = lines.count
        while start < end && blank(lines[start]) { start += 1 }
        while end > start && blank(lines[end - 1]) { end -= 1 }
        return Array(lines[start..<end])
    }
}

/// Keep extension slot overrides and built-in source selection equal in all hosts.
@MainActor
func registeredToolDefinition(_ name: String, session: AgentSession,
                              fallback: CustomTool? = nil) -> CustomTool? {
    session.hookRunner?.getExtensionTools().first { $0.name == name }
        ?? fallback ?? session.customTools.first { $0.tool.name == name }?.tool
}

@MainActor
func registeredToolRenderers(_ name: String, session: AgentSession,
                             fallback: CustomTool? = nil) -> ToolRenderers? {
    resolvedToolRenderers(name, session: session, fallback: fallback)
}

@MainActor
func installDefaultToolHtmlRenderer(_ session: AgentSession) {
    session.toolHtmlRenderer = TuiToolHtmlRenderer(theme: theme, cwd: session.sessionManager.getCwd(),
        getTheme: { theme }, getRenderers: { [weak session] name in
            guard let session else { return nil }
            return registeredToolRenderers(name, session: session)
        })
}
