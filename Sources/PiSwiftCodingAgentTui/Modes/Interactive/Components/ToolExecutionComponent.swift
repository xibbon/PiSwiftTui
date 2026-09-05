import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private let bashPreviewLines = 5

@MainActor
public struct ToolRendererDefinition {
    public var renderCall: (([String: AnyCodable], Theme) throws -> Component?)?
    public var renderResult: ((AgentToolResult, RenderResultOptions, Theme) throws -> Component?)?
}

/// Keep renderer lookup in the presentation package. Each custom slot wins independently.
@MainActor
public func withBuiltInRenderers(_ toolName: String, _ definition: CustomTool?) -> ToolRendererDefinition? {
    let builtIn = ["read", "bash", "edit", "write", "grep", "find", "ls"].contains(toolName)
    guard builtIn || definition != nil else { return nil }
    var merged = ToolRendererDefinition()
    if let call = definition?.renderCall {
        merged.renderCall = { args, theme in try call(args, theme) as? Component }
    } else if builtIn {
        merged.renderCall = { args, theme in
            let path = args["path"]?.value as? String ?? args["file_path"]?.value as? String ?? ""
            let title = toolName == "bash" ? "$ " + (args["command"]?.value as? String ?? "") : toolName + (path.isEmpty ? "" : " " + path)
            return Text(theme.fg(.toolTitle, theme.bold(title)), paddingX: 0, paddingY: 0)
        }
    }
    if let result = definition?.renderResult {
        merged.renderResult = { value, options, theme in try result(value, options, theme) as? Component }
    } else if toolName == "bash" {
        merged.renderResult = { result, options, theme in
            let output = result.content.compactMap { block -> String? in
                if case .text(let value) = block { return value.text }; return nil
            }.joined(separator: "\n")
            return output.isEmpty ? nil : BashResultPreview(output: output, expanded: options.expanded)
        }
    } else if builtIn {
        merged.renderResult = { result, options, theme in
            var text = result.content.compactMap { block -> String? in
                if case .text(let value) = block { return value.text }; return nil
            }.joined(separator: "\n")
            if toolName == "edit", let details = result.details?.value as? [String: Any], let diff = details["diff"] as? String {
                text += (text.isEmpty ? "" : "\n") + diff
            }
            guard !text.isEmpty else { return nil }
            let lines = text.components(separatedBy: "\n")
            let visible = options.expanded ? lines : Array(lines.prefix(10))
            var output = visible.map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
            if visible.count < lines.count { output += theme.fg(.muted, "\n... (\(lines.count - visible.count) more lines, ctrl+o to expand)") }
            return Text(output, paddingX: 0, paddingY: 0)
        }
    }
    return merged
}


private final class BashResultPreview: Component {
    let output: String
    let expanded: Bool
    init(output: String, expanded: Bool) { self.output = output; self.expanded = expanded }
    func render(width: Int) -> [String] {
        let styled = output.components(separatedBy: "\n").map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
        if expanded { return Text("\n" + styled, paddingX: 0, paddingY: 0).render(width: width) }
        let preview = truncateToVisualLines("\n" + styled, maxVisualLines: bashPreviewLines, width: max(1, width), paddingX: 0)
        var lines = preview.visualLines
        if preview.skippedCount > 0 {
            lines += Text("\n" + theme.fg(.dim, "... \(preview.skippedCount) more lines (ctrl+o to expand)"), paddingX: 0, paddingY: 0).render(width: width)
        }
        return lines
    }
}


public struct ToolExecutionOptions: Sendable {
    public var renderShell: ToolRenderShell
    public var showImages: Bool

    public init(showImages: Bool = true, renderShell: ToolRenderShell = .default) {
        self.renderShell = renderShell
        self.showImages = showImages
    }
}

@MainActor
public final class ToolExecutionComponent: Container {
    private let contentBox: Box
    private let renderShell: ToolRenderShell
    private let contentText: Text
    private var imageComponents: [Image] = []
    private var imageSpacers: [Spacer] = []
    private var convertedImages: [Int: ImageContent] = [:]
    private let toolName: String
    private var args: [String: AnyCodable]
    private var expanded = false
    private var showImages: Bool
    private var isPartial = true
    private let renderers: ToolRendererDefinition?
    private let ui: TUI
    private let cwd: String
    private var result: ToolResultMessage?
    private var editDiffPreview: String?
    private var editDiffArgsKey: String?

    public init(
        toolName: String,
        args: [String: AnyCodable],
        options: ToolExecutionOptions = ToolExecutionOptions(),
        customTool: CustomTool? = nil,
        ui: TUI,
        cwd: String = FileManager.default.currentDirectoryPath
    ) {
        self.renderShell = options.renderShell
        self.toolName = toolName
        self.args = args
        self.showImages = options.showImages
        self.renderers = withBuiltInRenderers(toolName, customTool)
        self.ui = ui
        self.cwd = cwd

        self.contentBox = Box(paddingX: options.renderShell == .self ? 0 : 1, paddingY: options.renderShell == .self ? 0 : 1, bgFn: { theme.bg(.toolPendingBg, $0) })
        self.contentText = Text("", paddingX: 1, paddingY: 1, customBgFn: { theme.bg(.toolPendingBg, $0) })

        super.init()

        addChild(Spacer(1))
        if renderers != nil {
            addChild(contentBox)
        } else {
            addChild(createResultRegion(contentText))
        }

        updateDisplay()
    }

    public override func render(width: Int) -> [String] {
        let lines = super.render(width: width)
        if renderShell == .self && lines.allSatisfy({ visibleWidth($0.replacingOccurrences(of: " ", with: "")) == 0 }) { return [] }
        return lines
    }

    public func updateArgs(_ args: [String: AnyCodable]) {
        self.args = args
        updateDisplay()
    }

    public func setArgsComplete() {
        maybeComputeEditDiff()
    }

    public func updateResult(_ result: ToolResultMessage, isPartial: Bool = false) {
        self.result = result
        self.isPartial = isPartial
        self.convertedImages = [:]
        updateDisplay()
        maybeConvertImagesForKitty()
    }

    public func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        updateDisplay()
    }

    public func setShowImages(_ show: Bool) {
        self.showImages = show
        updateDisplay()
    }

    public override func invalidate() {
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

    private func fallbackOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        let visible = expanded ? lines : Array(lines.prefix(10))
        let remaining = lines.count - visible.count
        var text = visible.map { theme.fg(.toolOutput, $0) }.joined(separator: "\n")
        if remaining > 0 {
            text += theme.fg(.muted, "\n... (\(remaining) more lines, ctrl+o to expand)")
        }
        return text
    }

    private func updateDisplay() {
        let bgFn: (String) -> String
        if renderShell == .self {
            bgFn = { $0 }
        } else if isPartial {
            bgFn = { theme.bg(.toolPendingBg, $0) }
        } else if result?.isError == true {
            bgFn = { theme.bg(.toolErrorBg, $0) }
        } else {
            bgFn = { theme.bg(.toolSuccessBg, $0) }
        }

        if let renderers {
            contentBox.setBgFn(bgFn)
            contentBox.clear()

            if let renderCall = renderers.renderCall {
                do {
                    if let component = try renderCall(args, theme) {
                        contentBox.addChild(component)
                    }
                } catch {
                    contentBox.addChild(Text(theme.fg(.toolTitle, theme.bold(toolName)), paddingX: 0, paddingY: 0))
                }
            } else {
                contentBox.addChild(Text(theme.fg(.toolTitle, theme.bold(toolName)), paddingX: 0, paddingY: 0))
            }

            if result == nil, let editDiffPreview { contentBox.addChild(Text(renderDiff(editDiffPreview), paddingX: 0, paddingY: 0)) }
            if let result {
                if let renderResult = renderers.renderResult {
                    do {
                        let options = RenderResultOptions(expanded: expanded, isPartial: isPartial)
                        let toolResult = AgentToolResult(content: result.content, details: result.details)
                        if let component = try renderResult(toolResult, options, theme) {
                            contentBox.addChild(createResultRegion(component))
                        }
                    } catch {
                        let output = getTextOutput()
                        if !output.isEmpty {
                            contentBox.addChild(createResultRegion(Text(fallbackOutput(output), paddingX: 0, paddingY: 0)))
                        }
                    }
                } else if toolName == "bash" {
                    renderBashContent(includeCall: false)
                } else {
                    let output = getTextOutput()
                    if !output.isEmpty {
                        contentBox.addChild(createResultRegion(Text(fallbackOutput(output), paddingX: 0, paddingY: 0)))
                    }
                }
            }
        } else if toolName == "bash" {
            contentBox.setBgFn(bgFn)
            contentBox.clear()
            renderBashContent()
        } else {
            contentText.setCustomBgFn(bgFn)
            contentText.setText(formatToolExecution())
        }

        for component in imageComponents {
            removeChild(component)
        }
        for spacer in imageSpacers {
            removeChild(spacer)
        }
        imageComponents.removeAll()
        imageSpacers.removeAll()

        if let result {
            let imageBlocks = result.content.compactMap { block -> ImageContent? in
                if case let .image(image) = block {
                    return image
                }
                return nil
            }

            let caps = getCapabilities()
            for (index, image) in imageBlocks.enumerated() {
                if caps.images != nil, showImages {
                    let resolvedImage = convertedImages[index] ?? image
                    if caps.images == .kitty, resolvedImage.mimeType != "image/png" {
                        continue
                    }
                    let spacer = Spacer(1)
                    addChild(spacer)
                    imageSpacers.append(spacer)
                    let imageComponent = Image(
                        base64Data: resolvedImage.data,
                        mimeType: resolvedImage.mimeType,
                        theme: ImageTheme(fallbackColor: { theme.fg(.toolOutput, $0) }),
                        options: ImageOptions(filename: nil)
                    )
                    addChild(imageComponent)
                    imageComponents.append(imageComponent)
                } else {
                    let spacer = Spacer(1)
                    addChild(spacer)
                    imageSpacers.append(spacer)
                    let dimensions = getImageDimensions(image.data, mimeType: image.mimeType)
                    let label = imageFallback(image.mimeType, dimensions: dimensions, filename: nil)
                    let fallback = Text(theme.fg(.toolOutput, label), paddingX: 1, paddingY: 0)
                    addChild(fallback)
                }
            }
        }
    }

    private func renderBashContent(includeCall: Bool = true) {
        let command = args["command"]?.value as? String ?? ""
        if includeCall { contentBox.addChild(Text(theme.fg(.toolTitle, theme.bold("$ \(command)")), paddingX: 0, paddingY: 0)) }

        let output = getTextOutput()
        if !output.isEmpty {
            let styled = output.split(separator: "\n", omittingEmptySubsequences: false).map {
                theme.fg(.toolOutput, String($0))
            }.joined(separator: "\n")

            if expanded {
                contentBox.addChild(createResultRegion(Text("\n" + styled, paddingX: 0, paddingY: 0)))
            } else {
                let contentWidth = max(1, ui.terminal.columns - 2)
                let truncation = truncateToVisualLines(
                    "\n" + styled,
                    maxVisualLines: bashPreviewLines,
                    width: contentWidth,
                    paddingX: 0
                )
                contentBox.addChild(createResultRegion(StaticLines(truncation.visualLines)))
                if truncation.skippedCount > 0 {
                    let hint = theme.fg(.dim, "... \(truncation.skippedCount) more lines (ctrl+o to expand)")
                    contentBox.addChild(createResultRegion(Text("\n" + hint, paddingX: 0, paddingY: 0)))
                }
            }
        }
    }

    private func formatToolExecution() -> String {
        var lines: [String] = []
        lines.append(theme.fg(.toolTitle, theme.bold(toolName)))

        if let argsText = formatArgs(args), !argsText.isEmpty {
            lines.append(theme.fg(.toolOutput, argsText))
        }

        if let editDiffPreview, result == nil {
            lines.append(renderDiff(editDiffPreview))
        }

        if let result {
            let output = getTextOutput(from: result)
            if !output.isEmpty {
                lines.append(fallbackOutput(output))
            }

            if let diff = extractDiff(from: result.details) {
                lines.append(renderDiff(diff))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatArgs(_ args: [String: AnyCodable]) -> String? {
        guard !args.isEmpty else { return nil }
        let jsonObject = args.mapValues { $0.jsonValue }
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            return String(describing: jsonObject)
        }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: options),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: jsonObject)
    }

    private func getTextOutput() -> String {
        guard let result else { return "" }
        return getTextOutput(from: result)
    }

    private func getTextOutput(from result: ToolResultMessage) -> String {
        let textBlocks = result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }
        let imageBlocks = result.content.compactMap { block -> ImageContent? in
            if case let .image(image) = block {
                return image
            }
            return nil
        }
        var output = textBlocks.joined(separator: "\n")
        let caps = getCapabilities()
        if !imageBlocks.isEmpty && (caps.images == nil || !showImages) {
            let labels = imageBlocks.map { image in
                let dimensions = getImageDimensions(image.data, mimeType: image.mimeType)
                return imageFallback(image.mimeType, dimensions: dimensions, filename: nil)
            }
            let combined = labels.joined(separator: "\n")
            output = output.isEmpty ? combined : "\(output)\n\(combined)"
        }
        return output
    }

    private func maybeConvertImagesForKitty() {
        let caps = getCapabilities()
        guard caps.images == .kitty, let result else { return }

        let imageBlocks = result.content.compactMap { block -> ImageContent? in
            if case let .image(image) = block {
                return image
            }
            return nil
        }

        for (index, image) in imageBlocks.enumerated() {
            if image.mimeType == "image/png" { continue }
            if convertedImages[index] != nil { continue }
            if let converted = convertToPng(image.data, image.mimeType) {
                convertedImages[index] = converted
                updateDisplay()
                ui.requestRender()
            }
        }
    }

    private func extractDiff(from details: AnyCodable?) -> String? {
        guard let details, let dict = details.value as? [String: Any] else {
            return nil
        }
        if let diff = dict["diff"] as? String {
            return diff
        }
        return nil
    }

    private func maybeComputeEditDiff() {
        guard toolName == "edit" else { return }
        guard let path = args["path"]?.value as? String else { return }
        guard let oldText = args["oldText"]?.value as? String else { return }
        guard let newText = args["newText"]?.value as? String else { return }

        let argsKey = "\(path)::\(oldText)::\(newText)"
        if editDiffArgsKey == argsKey {
            return
        }
        editDiffArgsKey = argsKey

        let diffResult = generateDiffString(oldText, newText)
        editDiffPreview = diffResult.diff
    }
}

private final class StaticLines: Component {
    private let lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func render(width: Int) -> [String] {
        _ = width
        return lines
    }
}
