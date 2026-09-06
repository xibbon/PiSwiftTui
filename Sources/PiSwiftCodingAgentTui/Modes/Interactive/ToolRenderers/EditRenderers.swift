import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@MainActor
private final class EditCallRenderComponent: Box {
    var preview: EditDiffOutcome?
    var computedPreview: EditDiffOutcome?
    var previewArgsKey: String?
    var previewPending = false
    var settledError = false
}

private struct EditPreviewInput {
    var path: String
    var edits: [EditReplacement]

    var key: String {
        let value: [String: Any] = ["path": path, "edits": edits.map { ["oldText": $0.oldText, "newText": $0.newText] }]
        return String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}

private func editPreviewInput(_ args: [String: AnyCodable]) -> EditPreviewInput? {
    guard let path = (args["path"]?.value as? String) ?? (args["file_path"]?.value as? String), !path.isEmpty else { return nil }
    if let rawEdits = args["edits"]?.value as? [[String: Any]], !rawEdits.isEmpty {
        let edits = rawEdits.compactMap { edit -> EditReplacement? in
            guard let oldText = edit["oldText"] as? String, let newText = edit["newText"] as? String else { return nil }
            return EditReplacement(oldText: oldText, newText: newText)
        }
        if edits.count == rawEdits.count { return EditPreviewInput(path: path, edits: edits) }
    }
    if let oldText = args["oldText"]?.value as? String, let newText = args["newText"]?.value as? String {
        return EditPreviewInput(path: path, edits: [EditReplacement(oldText: oldText, newText: newText)])
    }
    return nil
}

@MainActor
private func editCallComponent(_ context: ToolRenderContext) -> EditCallRenderComponent {
    let component = (context.lastComponent as? EditCallRenderComponent)
        ?? (context.state.values["editCallComponent"] as? EditCallRenderComponent)
        ?? EditCallRenderComponent(paddingX: 1, paddingY: 1, bgFn: { $0 })
    context.state.values["editCallComponent"] = component
    return component
}

@MainActor
private func buildEditCall(_ component: EditCallRenderComponent, args: [String: AnyCodable], theme: Theme, cwd: String) {
    switch component.preview {
    case .success: component.setBgFn { theme.bg(.toolSuccessBg, $0) }
    case .error: component.setBgFn { theme.bg(.toolErrorBg, $0) }
    case nil:
        let background: ThemeBg = component.settledError ? .toolErrorBg : .toolPendingBg
        component.setBgFn { theme.bg(background, $0) }
    }
    component.clear()
    let path = renderToolPath(str(toolPathArgument(args)), theme, cwd)
    component.addChild(Text(theme.fg(.toolTitle, theme.bold("edit")) + " " + path, paddingX: 0, paddingY: 0))
    guard let preview = component.preview else { return }
    let body: String
    switch preview {
    case .error(let error): body = theme.fg(.error, error.error)
    case .success(let result): body = renderDiff(result.diff)
    }
    component.addChild(Spacer(1))
    component.addChild(Text(body, paddingX: 0, paddingY: 0))
}

@MainActor
@discardableResult
private func setEditPreview(_ component: EditCallRenderComponent, preview: EditDiffOutcome, argsKey: String?) -> Bool {
    let changed: Bool
    switch (component.preview, preview) {
    case (.error(let current), .error(let next)): changed = current.error != next.error
    case (.success(let current), .success(let next)):
        changed = current.diff != next.diff || current.firstChangedLine != next.firstChangedLine
    default: changed = true
    }
    component.preview = preview
    component.previewArgsKey = argsKey
    component.previewPending = false
    return changed
}

@MainActor
public func createEditRenderers() -> ToolRenderers {
    ToolRenderers(
        renderShell: .self,
        renderCall: { args, theme, context in
            let component = editCallComponent(context)
            let input = editPreviewInput(args)
            let argsKey = input?.key
            if component.previewArgsKey != argsKey {
                component.preview = nil
                component.computedPreview = nil
                component.previewArgsKey = argsKey
                component.previewPending = false
                component.settledError = false
            }
            if context.argsComplete, let input, component.preview == nil, !component.previewPending {
                component.previewPending = true
                // The library API is synchronous. Defer the work to the next actor turn so an
                // invalidation cannot enter the row's current display update a second time.
                Task { @MainActor [weak component] in
                    guard let component, component.previewArgsKey == argsKey, component.previewPending else { return }
                    let preview = computeEditsDiff(path: input.path, edits: input.edits, cwd: context.cwd)
                    guard component.previewArgsKey == argsKey else { return }
                    component.computedPreview = preview
                    if setEditPreview(component, preview: preview, argsKey: argsKey) { context.invalidate() }
                }
            }
            buildEditCall(component, args: args, theme: theme, cwd: context.cwd)
            return component
        },
        renderResult: { result, _, theme, context in
            let call = context.state.values["editCallComponent"] as? EditCallRenderComponent
            let previousPreview = call?.computedPreview
            let argsKey = editPreviewInput(context.args)?.key
            let details = toolDetails(result)
            let resultDiff = context.isError ? nil : details["diff"] as? String
            if let call {
                var changed = false
                if let resultDiff {
                    changed = setEditPreview(call, preview: .success(EditDiffResult(diff: resultDiff, firstChangedLine: details["firstChangedLine"] as? Int)), argsKey: argsKey)
                }
                if call.settledError != context.isError {
                    call.settledError = context.isError
                    changed = true
                }
                if changed { buildEditCall(call, args: context.args, theme: theme, cwd: context.cwd) }
            }
            var output: String?
            if context.isError {
                let errorText = result.content.compactMap { block -> String? in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined(separator: "\n")
                let previewError: String?
                if case .error(let error) = previousPreview { previewError = error.error } else { previewError = nil }
                if !errorText.isEmpty && errorText != previewError { output = theme.fg(.error, errorText) }
            } else if let resultDiff, !resultDiff.isEmpty {
                let previewDiff: String?
                if case .success(let preview) = previousPreview { previewDiff = preview.diff } else { previewDiff = nil }
                if resultDiff != previewDiff {
                    output = renderDiff(resultDiff, RenderDiffOptions(filePath: str(toolPathArgument(context.args))))
                }
            }
            let component = (context.lastComponent as? Container) ?? Container()
            component.clear()
            if let output {
                component.addChild(Spacer(1))
                component.addChild(Text(output, paddingX: 1, paddingY: 0))
            }
            return component
        }
    )
}
