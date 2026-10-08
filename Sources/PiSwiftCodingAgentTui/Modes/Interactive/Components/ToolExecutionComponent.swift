import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

public struct ToolExecutionOptions: Sendable {
    public var outputPad: Int
    public var showImages: Bool
    public var imageWidthCells: Int

    public init(showImages: Bool = true, imageWidthCells: Int = 60, outputPad: Int = 1) {
        self.outputPad = outputPad
        self.showImages = showImages
        self.imageWidthCells = max(1, imageWidthCells)
    }
}

@MainActor
public final class ToolExecutionComponent: Container, OutputPaddingSetting {
    private let contentBox: Box
    private let contentText: Text
    private let selfRenderContainer = Container()
    private var selfRenderHeight = 0
    private var callRendererComponent: Component?
    private var resultRendererComponent: Component?
    private let rendererState = ToolRenderState()
    private var imageComponents: [Image] = []
    private var imageSpacers: [Spacer] = []
    private struct ImageSource: Equatable {
        let data: String
        let mimeType: String
        let widthCells: Int
    }
    private var imageSources: [ImageSource] = []
    private let toolName: String
    private let toolCallId: String
    private var args: [String: AnyCodable]
    private var expanded = false
    private var showImages: Bool
    private var imageWidthCells: Int
    private var outputPad: Int
    private var isPartial = true
    private var executionStarted = false
    private var argsComplete = false
    private let renderers: ToolRenderers?
    private let ui: TUI
    private let cwd: String
    private var result: ToolResultMessage?
    private var hideComponent = false
    private var updatingDisplay = false
    private var displayInvalidated = false
    private var renderShell: ToolRenderShell { renderers?.renderShell ?? .default }

    public init(
        toolName: String,
        toolCallId: String = "",
        args: [String: AnyCodable],
        options: ToolExecutionOptions = ToolExecutionOptions(),
        customTool: CustomTool? = nil,
        sourceInfo: SourceInfo? = nil,
        renderers: ToolRenderers? = nil,
        ui: TUI,
        cwd: String = FileManager.default.currentDirectoryPath
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.args = args
        self.outputPad = options.outputPad
        self.showImages = options.showImages
        self.imageWidthCells = options.imageWidthCells
        self.renderers = renderers ?? withBuiltInRenderers(toolName, customTool, sourceInfo: sourceInfo)
        self.ui = ui
        self.cwd = cwd
        self.contentBox = Box(paddingX: options.outputPad, paddingY: 1, bgFn: { theme.bg(.toolPendingBg, $0) })
        self.contentText = Text("", paddingX: options.outputPad, paddingY: 1, customBgFn: { theme.bg(.toolPendingBg, $0) })
        super.init()
        addChild(Spacer(1))
        if self.renderers != nil {
            addChild(renderShell == .self ? selfRenderContainer : contentBox)
        } else {
            addChild(createResultRegion(contentText))
        }
        updateDisplay()
    }

    private func getRenderContext(_ lastComponent: Component?) -> ToolRenderContext {
        ToolRenderContext(
            args: args, toolCallId: toolCallId,
            invalidate: { [weak self] in
                guard let self else { return }
                self.invalidate()
                self.ui.requestRender()
            },
            lastComponent: lastComponent, state: rendererState, cwd: cwd,
            executionStarted: executionStarted, argsComplete: argsComplete,
            isPartial: isPartial, expanded: expanded, showImages: showImages,
            isError: result?.isError ?? false,
            durationMs: isPartial ? nil : result?.durationMs, outputPad: outputPad
        )
    }

    public override func render(width: Int) -> [String] {
        if hideComponent { return [] }
        if renderers != nil, renderShell == .self {
            let contentLines = selfRenderContainer.render(width: width)
            selfRenderHeight = contentLines.count
            if contentLines.isEmpty && imageComponents.isEmpty { return [] }
            var lines = contentLines.isEmpty ? [] : [""] + contentLines
            for (index, image) in imageComponents.enumerated() {
                lines += imageSpacers[index].render(width: width)
                lines += image.render(width: width)
            }
            return lines
        }
        return super.render(width: width)
    }

    public override func handleMouse(_ event: TuiMouseEvent) -> TuiMouseEventResult? {
        guard renderers != nil, renderShell == .self else { return super.handleMouse(event) }
        guard event.y > 0, event.y <= selfRenderHeight else { return nil }
        var local = event
        local.y -= 1
        local.height = selfRenderHeight
        return selfRenderContainer.handleMouse(local)
    }

    public func updateArgs(_ args: [String: AnyCodable]) {
        self.args = args
        updateDisplay()
    }

    public func markExecutionStarted() {
        executionStarted = true
        // The Swift bash tool sends partial results only when output arrives.
        // Start the result slot now so a silent command still shows elapsed time.
        if toolName == "bash", result == nil {
            result = ToolResultMessage(toolCallId: toolCallId, toolName: toolName, content: [], isError: false)
        }
        updateDisplay()
        ui.requestRender()
    }

    public func setArgsComplete() {
        argsComplete = true
        updateDisplay()
        ui.requestRender()
    }

    public func updateResult(_ result: ToolResultMessage, isPartial: Bool = false) {
        self.result = result
        self.isPartial = isPartial
        updateDisplay()
    }

    public func setOutputPad(_ outputPad: Int) {
        self.outputPad = outputPad
        updateDisplay()
    }

    public func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        updateDisplay()
    }

    public func setShowImages(_ show: Bool) {
        showImages = show
        updateDisplay()
    }

    public func setImageWidthCells(_ width: Int) {
        imageWidthCells = max(1, width)
        updateDisplay()
    }

    public override func invalidate() {
        if updatingDisplay {
            displayInvalidated = true
            return
        }
        super.invalidate()
        updateDisplay()
    }

    private func createResultRegion(_ component: Component) -> MouseRegion {
        MouseRegion(child: component) { [weak self] event in
            guard let self, self.result != nil, event.type == .click, event.button == .left else { return nil }
            self.setExpanded(!self.expanded)
            return TuiMouseEventResult(handled: true)
        }
    }

    private func createCallFallback() -> Component {
        Text(formatToolCallWithArgs(toolName, args: args, theme: theme, expanded: expanded), paddingX: 0, paddingY: 0)
    }

    private func fallbackOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        let visible = expanded ? lines : Array(lines.prefix(10))
        var text = visible.map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
        let remaining = lines.count - visible.count
        if remaining > 0 {
            text += theme.fg(.muted, "\n... (\(remaining) more lines,") + " "
                + keyHint(.expandTools, "to expand") + theme.fg(.muted, ")")
        }
        return text
    }

    private func textOutput() -> String {
        guard let result else { return "" }
        return getTextOutput(AgentToolResult(content: result.content, details: result.details), showImages: showImages)
    }

    private func createResultFallback() -> Component? {
        let output = textOutput()
        return output.isEmpty ? nil : Text(fallbackOutput(output), paddingX: 0, paddingY: 0)
    }

    private func updateDisplay() {
        guard !updatingDisplay else { displayInvalidated = true; return }
        updatingDisplay = true
        defer {
            updatingDisplay = false
            if displayInvalidated {
                displayInvalidated = false
                // A synchronous renderer can change shared state while the slots render.
                // Defer its next pass to avoid re-entering the container mutation.
                Task { @MainActor [weak self] in self?.invalidate() }
            }
        }
        let bgFn: (String) -> String = isPartial
            ? { theme.bg(.toolPendingBg, $0) }
            : result?.isError == true
                ? { theme.bg(.toolErrorBg, $0) }
                : { theme.bg(.toolSuccessBg, $0) }
        var hasContent = false
        hideComponent = false
        if let renderers {
            let addRenderedChild: (Component) -> Void
            if renderShell == .self {
                selfRenderContainer.clear()
                addRenderedChild = selfRenderContainer.addChild
            } else {
                contentBox.setPaddingX(outputPad)
                contentBox.setBgFn(bgFn)
                contentBox.clear()
                addRenderedChild = contentBox.addChild
            }
            let call: Component
            if let renderer = renderers.renderCall {
                do {
                    call = try renderer(args, theme, getRenderContext(callRendererComponent))
                    callRendererComponent = call
                } catch {
                    callRendererComponent = nil
                    call = createCallFallback()
                }
            } else {
                call = createCallFallback()
            }
            addRenderedChild(createResultRegion(call))
            hasContent = true
            if let result {
                var renderedResult: Component?
                if let renderer = renderers.renderResult {
                    do {
                        renderedResult = try renderer(
                            AgentToolResult(content: result.content, details: result.details),
                            RenderResultOptions(expanded: expanded, isPartial: isPartial, durationMs: isPartial ? nil : result.durationMs, outputPad: outputPad), theme,
                            getRenderContext(resultRendererComponent)
                        )
                        resultRendererComponent = renderedResult
                    } catch {
                        resultRendererComponent = nil
                        renderedResult = createResultFallback()
                    }
                } else {
                    renderedResult = createResultFallback()
                }
                if let renderedResult {
                    addRenderedChild(createResultRegion(renderedResult))
                    hasContent = true
                }
            }
        } else {
            contentText.setPaddingX(outputPad)
            contentText.setCustomBgFn(bgFn)
            contentText.setText(formatToolExecution())
            hasContent = true
        }
        if let nested = result?.nestedCalls, !nested.calls.isEmpty {
            let text = nested.calls.map { call in
                let args = toolArgumentsWithOrder(call.arguments ?? [:], argumentsJSON: call.argumentsJSON)
                return formatToolCallWithArgs(call.name, args: args, theme: theme, expanded: expanded)
            }.joined(separator: "\n")
            let component = createResultRegion(Text(text, paddingX: 0, paddingY: 0))
            if renderers != nil {
                if renderShell == .self { selfRenderContainer.addChild(component) }
                else { contentBox.addChild(component) }
            } else {
                contentText.setText(formatToolExecution() + "\n" + text)
            }
            hasContent = true
        }
        let previousImages = imageComponents
        let previousSources = imageSources
        for image in imageComponents { removeChild(image) }
        for spacer in imageSpacers { removeChild(spacer) }
        imageComponents.removeAll()
        imageSources.removeAll()
        imageSpacers.removeAll()
        if let result, getCapabilities().images != nil, showImages {
            let images = result.content.compactMap { block -> ImageContent? in
                if case .image(let image) = block { return image }
                return nil
            }
            for image in images where !image.data.isEmpty && !image.mimeType.isEmpty {
                let source = ImageSource(data: image.data, mimeType: image.mimeType, widthCells: imageWidthCells)
                let index = imageComponents.count
                if source.mimeType != "image/png" { ensurePngTranscoder() }
                let spacer = Spacer(1)
                let component: Image
                if previousSources.indices.contains(index), previousSources[index] == source {
                    component = previousImages[index]
                } else {
                    component = Image(
                        base64Data: source.data, mimeType: source.mimeType,
                        theme: ImageTheme(fallbackColor: { theme.fg(.toolOutput, $0) }),
                        options: ImageOptions(maxWidthCells: source.widthCells)
                    )
                }
                addChild(spacer)
                addChild(component)
                imageSpacers.append(spacer)
                imageComponents.append(component)
                imageSources.append(source)
            }
        }
        hideComponent = renderers != nil && !hasContent && imageComponents.isEmpty
    }

    private func formatToolExecution() -> String {
        var text = formatToolCallWithArgs(toolName, args: args, theme: theme, expanded: expanded)
        let output = textOutput()
        if !output.isEmpty { text += "\n" + fallbackOutput(output) }
        return text
    }
}
