import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private final class T1DialogResources: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

private final class T1DialogTerminal: Terminal {
    var columns = 80
    var rows = 24
    var kittyProtocolActive = false
    var supportsTerminalQueries = true
    var writes = ""
    var input: ((String) -> Void)?
    func start(onInput: @escaping (String) -> Void, onResize: @escaping () -> Void) { input = onInput }
    func stop() { input = nil }
    func drainInput(maxMs: Int, idleMs: Int) {}
    func write(_ data: String) { writes += data }
    func moveBy(lines: Int) {}
    func hideCursor() {}
    func showCursor() {}
    func clearLine() {}
    func clearFromCursor() {}
    func clearScreen() {}
    func setTitle(_ title: String) {}
}

@MainActor
private func t1WaitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() && ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition())
}

/// Check completion before reading a task result, so a failed test cannot wait forever.
@MainActor
private final class T1DialogResult<Value: Sendable> {
    private var result: Value?
    private(set) var completed = false
    private var task: Task<Void, Never>?

    init(_ operation: @escaping @MainActor () async -> Value) {
        task = Task { @MainActor in
            result = await operation()
            completed = true
        }
    }

    func cancel() { task?.cancel() }

    func value() async throws -> Value {
        try await t1WaitUntil { completed }
        return try #require(result)
    }
}

@MainActor
private final class T1DialogProbe: Component, Focusable, @MainActor HookDisposableComponent {
    let label: String
    var focused = false
    var close: HookCustomClose?
    var inputs: [String] = []
    var onInput: (() -> Void)?
    var onDispose: (() -> Void)?
    private(set) var disposeCount = 0

    init(_ label: String) { self.label = label }
    func render(width: Int) -> [String] { [label] }
    func handleInput(_ data: String) { inputs.append(data); onInput?() }
    func dispose() { disposeCount += 1; onDispose?() }
}

@MainActor
private final class T1SelectorProbe: Component, Focusable, SelectorClosable {
    var focused = false
    private(set) var closeCount = 0
    func render(width: Int) -> [String] { ["built-in selector"] }
    func closeSelector() { closeCount += 1 }
}

/// The factory can finish after its caller has been cancelled or the host has stopped.
@MainActor
private final class T1FactoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        guard !released else { return }
        released = true
        let saved = continuation
        continuation = nil
        saved?.resume()
    }
}

enum T1DialogKind: String, CaseIterable, Sendable {
    case select, confirm, input, editor, custom, overlay
}

enum T1DialogEnd: String, CaseIterable, Sendable {
    case reset, reload, shutdown
}

@MainActor
private struct T1DialogHost {
    let session: AgentSession
    let runner: HookRunner
    let terminal: T1DialogTerminal
    let tui: TUI
    let editor: CustomEditor
    let mode: InteractiveMode

    init() {
        initTheme("dark")
        let manager = SessionManager.inMemory("/tmp")
        let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        runner = HookRunner([], "/tmp", manager, registry)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: t3aModel(), tools: [])))
        session = AgentSession(config: AgentSessionConfig(
            agent: agent, sessionManager: manager, settingsManager: .inMemory(),
            resourceLoader: T1DialogResources(), hookRunner: runner, modelRegistry: registry,
            reloadExtensionsHook: { LoadExtensionsResult(hooks: []) }
        ))
        terminal = T1DialogTerminal()
        tui = TUI(terminal: terminal)
        tui.programStatusEnvironment = { "1" }
        editor = CustomEditor(ui: tui, theme: getEditorTheme(), keybindings: .inMemory())
        mode = InteractiveMode(session: session, tui: tui, editor: editor)
        if let container = mode.editorContainer { tui.addChild(container) }
        tui.setFocus(editor)
    }

    var context: any HookUIContext { runner.getUIContext() }

    func start() async {
        await mode.initializeHooksAndCustomTools()
        tui.start()
        mode.programStatus.report()
    }

    func close() {
        mode.resetExtensionDialogs()
        mode.handleAgentEvent(.agentEnd(messages: []))
        tui.stop()
        session.dispose()
    }

    var visible: String { mode.editorContainer?.render(width: 80).joined(separator: "\n") ?? "" }
    var transcript: String { mode.chatContainer.render(width: 120).joined(separator: "\n") }

    var reports: [ProgramStatus] {
        terminal.writes.components(separatedBy: "\u{1B}]7501;").dropFirst().compactMap { fragment in
            let payload = fragment.components(separatedBy: "\u{1B}\\")[0].components(separatedBy: "\u{7}")[0]
            let fields = Dictionary(payload.split(separator: ":").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]).removingPercentEncoding ?? String(parts[1]))
            }, uniquingKeysWith: { _, new in new })
            guard let raw = fields["state"], let state = ProgramStatus.State(rawValue: raw) else { return nil }
            return ProgramStatus(
                state: state, app: fields["app"], kind: fields["kind"].flatMap(ProgramStatus.Kind.init(rawValue:)),
                message: fields["msg"].flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
            )
        }
    }

    func waitForVisible(_ label: String) async throws {
        try await t1WaitUntil { visible.contains(label) }
        let container = try #require(mode.editorContainer)
        #expect(container.children.count == 1)
        #expect(container.children.first === tui.getFocusedComponent())
    }

    func expectEditor() {
        #expect(mode.editorContainer?.children.count == 1)
        #expect(mode.editorContainer?.children.first === editor)
        #expect(tui.getFocusedComponent() === editor)
    }

    func openCustom(_ probe: T1DialogProbe, overlay: Bool = false, gate: T1FactoryGate? = nil) -> T1DialogResult<HookCustomResult?> {
        let ui = context
        return T1DialogResult {
            await ui.custom({ _, _, _, done in
                await MainActor.run { probe.close = done }
                if let gate { await gate.wait() }
                return await MainActor.run { probe }
            }, options: HookCustomOptions(overlay: overlay))
        }
    }

    func open(_ kind: T1DialogKind, _ label: String, probe: T1DialogProbe) -> T1DialogResult<String?> {
        let ui = context
        return T1DialogResult {
            switch kind {
            case .select: return await ui.select(label, ["first", "second"])
            case .confirm: return await ui.confirm(label, "Private message") ? "accepted" : nil
            case .input: return await ui.input(label, "Private placeholder")
            case .editor: return await ui.editor(label, "prefill")
            case .custom, .overlay:
                return await ui.custom({ _, _, _, done in
                    await MainActor.run { probe.close = done }
                    return await MainActor.run { probe }
                }, options: HookCustomOptions(overlay: kind == .overlay))?.value as? String
            }
        }
    }
}

@MainActor @Suite(.serialized)
struct T1ExtensionDialogTests {
    // Upstream v1.4.0 interactive-mode-extension-dialogs.test.ts: all four cases.
    @Test func laterConfirmRestoresEarlierConfirmAndStatus() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let first = T1DialogResult { await ui.confirm("First", "Private first message") }
        try await host.waitForVisible("First")
        let firstComponent = host.tui.getFocusedComponent()
        let second = T1DialogResult { await ui.confirm("Second", "Private second message") }
        try await host.waitForVisible("Second")
        #expect(host.reports.last?.state == .blocked)
        #expect(host.reports.last?.kind == .permission)
        #expect(host.reports.last?.message == "Second")
        host.tui.getFocusedComponent()?.handleInput("\u{1B}")
        #expect(try await second.value() == false)
        try await host.waitForVisible("First")
        #expect(host.tui.getFocusedComponent() === firstComponent)
        #expect(host.reports.last?.kind == .permission)
        #expect(host.reports.last?.message == "First")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await first.value())
        host.expectEditor()
        #expect(host.reports.last?.state == .idle)
        #expect(!host.reports.contains { $0.message?.contains("Private") == true })
    }

    @Test func cancellationRemovesHiddenConfirm() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let first = T1DialogResult { await ui.confirm("Hidden confirm", "First") }
        try await host.waitForVisible("Hidden confirm")
        let second = T1DialogResult { await ui.confirm("Visible confirm", "Second") }
        try await host.waitForVisible("Visible confirm")
        let visible = host.tui.getFocusedComponent()
        first.cancel()
        #expect(try await first.value() == false)
        #expect(host.tui.getFocusedComponent() === visible)
        #expect(host.visible.contains("Visible confirm"))
        #expect(host.reports.last?.message == "Visible confirm")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await second.value())
        host.expectEditor()
        #expect(host.reports.last?.state == .idle)
    }

    @Test func concurrentInlineCustomComponentsRestoreInOrder() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        host.editor.setText("saved draft")
        let firstProbe = T1DialogProbe("custom one")
        let secondProbe = T1DialogProbe("custom two")
        let first = host.openCustom(firstProbe)
        try await host.waitForVisible(firstProbe.label)
        let second = host.openCustom(secondProbe)
        try await host.waitForVisible(secondProbe.label)
        secondProbe.close?("two")
        #expect(try await second.value()?.value as? String == "two")
        try await host.waitForVisible(firstProbe.label)
        #expect(host.tui.getFocusedComponent() === firstProbe)
        #expect(secondProbe.disposeCount == 1)
        firstProbe.close?("one")
        #expect(try await first.value()?.value as? String == "one")
        host.expectEditor()
        #expect(host.editor.getText() == "saved draft")
        firstProbe.close?("duplicate")
        secondProbe.close?("duplicate")
        #expect(firstProbe.disposeCount == 1)
        #expect(secondProbe.disposeCount == 1)
    }

    @Test func inlineCustomCanOpenConfirmAndResumeInput() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let probe = T1DialogProbe("custom form")
        var confirm: T1DialogResult<Bool>?
        probe.onInput = { confirm = T1DialogResult { await ui.confirm("Discard?", "Private changes") } }
        let custom = host.openCustom(probe)
        try await host.waitForVisible(probe.label)
        host.tui.getFocusedComponent()?.handleInput("x")
        try await host.waitForVisible("Discard?")
        host.tui.getFocusedComponent()?.handleInput("\u{1B}")
        let answer = try #require(confirm)
        #expect(try await answer.value() == false)
        try await host.waitForVisible(probe.label)
        #expect(host.tui.getFocusedComponent() === probe)
        probe.onInput = nil
        host.tui.getFocusedComponent()?.handleInput("y")
        #expect(probe.inputs == ["x", "y"])
        probe.close?("kept")
        #expect(try await custom.value()?.value as? String == "kept")
        host.expectEditor()
    }

    // Upstream v1.4.0 interactive-mode-status.test.ts:246-312.
    @Test func overlayReclaimsInputAfterInlineCustomCloses() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let palette = T1DialogProbe("palette")
        host.tui.addChild(palette)
        host.tui.setFocus(palette)
        let overlay = T1DialogProbe("overlay")
        let overlayResult = host.openCustom(overlay, overlay: true)
        try await t1WaitUntil { overlay.focused }
        let inline = T1DialogProbe("replacement")
        let inlineResult = host.openCustom(inline)
        try await host.waitForVisible(inline.label)
        inline.close?("done")
        #expect(try await inlineResult.value()?.value as? String == "done")
        try await t1WaitUntil { overlay.focused }
        host.terminal.input?("x")
        try await t1WaitUntil { overlay.inputs == ["x"] }
        #expect(host.tui.getFocusedComponent() === overlay)
        #expect(host.editor.getText().isEmpty)
        #expect(palette.inputs.isEmpty)
        overlay.close?("closed")
        #expect(try await overlayResult.value()?.value as? String == "closed")
        #expect(!host.tui.hasOverlay())
    }

    @Test func closingOverlayDoesNotRestoreAClosedInlineDialog() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let inline = T1DialogProbe("inline below overlay")
        let inlineResult = host.openCustom(inline)
        try await host.waitForVisible(inline.label)
        let overlay = T1DialogProbe("overlay above inline")
        let overlayResult = host.openCustom(overlay, overlay: true)
        try await t1WaitUntil { overlay.focused }
        inline.close?("inline closed")
        #expect(try await inlineResult.value()?.value as? String == "inline closed")
        #expect(host.tui.getFocusedComponent() === overlay)
        overlay.close?("overlay closed")
        #expect(try await overlayResult.value()?.value as? String == "overlay closed")
        #expect(!host.tui.hasOverlay())
        host.expectEditor()
        #expect(inline.disposeCount == 1)
        #expect(overlay.disposeCount == 1)
    }

    @Test func mixedDialogKindsKeepTheirStateAndReturnValues() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        host.editor.setText("draft text")
        let ui = host.context
        let select = T1DialogResult { await ui.select("Choose", ["first", "second"]) }
        try await host.waitForVisible("Choose")
        host.tui.getFocusedComponent()?.handleInput("\u{1B}[B")
        let selection = host.tui.getFocusedComponent()
        let input = T1DialogResult { await ui.input("Input", nil) }
        try await host.waitForVisible("Input")
        host.tui.getFocusedComponent()?.handleInput("typed value")
        let inputComponent = host.tui.getFocusedComponent()
        let editor = T1DialogResult { await ui.editor("Edit", "editor value") }
        try await host.waitForVisible("Edit")
        let editorComponent = host.tui.getFocusedComponent()
        let probe = T1DialogProbe("custom top")
        let custom = host.openCustom(probe)
        try await host.waitForVisible(probe.label)
        #expect(!select.completed)
        #expect(!input.completed)
        #expect(!editor.completed)
        probe.close?("custom value")
        #expect(try await custom.value()?.value as? String == "custom value")
        try await host.waitForVisible("Edit")
        #expect(host.tui.getFocusedComponent() === editorComponent)
        host.tui.getFocusedComponent()?.handleInput("\u{1B}[13;5u")
        #expect(try await editor.value() == "editor value")
        try await host.waitForVisible("Input")
        #expect(host.tui.getFocusedComponent() === inputComponent)
        #expect(host.reports.last?.kind == .question)
        #expect(host.reports.last?.message == "Input")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await input.value() == "typed value")
        try await host.waitForVisible("Choose")
        #expect(host.tui.getFocusedComponent() === selection)
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await select.value() == "second")
        host.expectEditor()
        #expect(host.editor.getText() == "draft text")
        #expect(host.reports.last?.state == .idle)
    }

    @Test func cancellationRemovesHiddenInputWithoutChangingVisibleConfirm() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let input = T1DialogResult { await ui.input("Hidden input", "private") }
        try await host.waitForVisible("Hidden input")
        let confirm = T1DialogResult { await ui.confirm("Top confirm", "private") }
        try await host.waitForVisible("Top confirm")
        let component = host.tui.getFocusedComponent()
        input.cancel()
        #expect(try await input.value() == nil)
        #expect(host.tui.getFocusedComponent() === component)
        #expect(host.reports.last?.message == "Top confirm")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await confirm.value())
        host.expectEditor()
    }

    @Test(arguments: T1DialogKind.allCases)
    func taskCancellationSettlesEachDialogKind(_ kind: T1DialogKind) async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let probe = T1DialogProbe("cancel \(kind.rawValue)")
        let result = host.open(kind, probe.label, probe: probe)
        if kind == .overlay { try await t1WaitUntil { probe.focused } }
        else { try await host.waitForVisible(probe.label) }
        result.cancel()
        #expect(try await result.value() == nil)
        host.expectEditor()
        #expect(!host.tui.hasOverlay())
        #expect(host.reports.last?.state == .idle)
        if kind == .custom || kind == .overlay {
            probe.close?("late close")
            #expect(probe.disposeCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func taskCancellationSettlesPendingCustomFactory(_ overlay: Bool) async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let probe = T1DialogProbe("late factory")
        let gate = T1FactoryGate()
        defer { gate.release() }
        let result = host.openCustom(probe, overlay: overlay, gate: gate)
        try await t1WaitUntil { gate.entered }
        result.cancel()
        #expect(try await result.value() == nil)
        gate.release()
        try await t1WaitUntil { probe.disposeCount == 1 }
        probe.close?("late close")
        #expect(probe.disposeCount == 1)
        #expect(!host.tui.hasOverlay())
        host.expectEditor()
    }

    @Test(arguments: T1DialogKind.allCases)
    func globalClearSettlesOnlyVisibleDialog(_ kind: T1DialogKind) async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let first = T1DialogResult { await ui.confirm("Lower confirm", "private") }
        try await host.waitForVisible("Lower confirm")
        let probe = T1DialogProbe("Visible \(kind.rawValue)")
        let second = host.open(kind, probe.label, probe: probe)
        if kind == .overlay { try await t1WaitUntil { probe.focused } }
        else { try await host.waitForVisible(probe.label) }
        host.mode.handleGlobalClear()
        #expect(try await second.value() == nil)
        try await host.waitForVisible("Lower confirm")
        #expect(!first.completed)
        #expect(host.reports.last?.message == "Lower confirm")
        if kind == .custom || kind == .overlay {
            probe.close?("late close")
            #expect(probe.disposeCount == 1)
        }
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await first.value())
        host.expectEditor()
    }

    @Test func invalidCustomFactoryResultSettlesAndShowsDiagnostic() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let lower = T1DialogResult { await ui.confirm("Keep this confirm", "private") }
        try await host.waitForVisible("Keep this confirm")
        let component = host.tui.getFocusedComponent()
        let invalid = T1DialogResult { await ui.custom({ _, _, _, _ in "invalid component" }, options: nil) }
        #expect(try await invalid.value() == nil)
        #expect(host.tui.getFocusedComponent() === component)
        let diagnostic = host.transcript.lowercased()
        #expect(diagnostic.contains("custom"))
        #expect(diagnostic.contains("component"))
        #expect(host.reports.last?.message == "Keep this confirm")
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await lower.value())
        host.expectEditor()
    }

    @Test func resetCanRunAgainDuringCustomDisposal() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let lower = T1DialogProbe("lower reset")
        let upper = T1DialogProbe("upper reset")
        lower.onDispose = { host.mode.resetExtensionDialogs() }
        upper.onDispose = { host.mode.resetExtensionDialogs() }
        let lowerResult = host.openCustom(lower)
        try await host.waitForVisible(lower.label)
        let upperResult = host.openCustom(upper, overlay: true)
        try await t1WaitUntil { upper.focused }
        host.mode.resetExtensionDialogs()
        #expect(try await lowerResult.value() == nil)
        #expect(try await upperResult.value() == nil)
        lower.close?("late close")
        upper.close?("late close")
        #expect(lower.disposeCount == 1)
        #expect(upper.disposeCount == 1)
        #expect(!host.tui.hasOverlay())
        host.expectEditor()
    }

    @Test func extensionPushClosesBuiltInSelectorAndRejectsItsStaleDoneCallback() async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        let ui = host.context
        let lower = T1DialogResult { await ui.confirm("Lower extension", "private") }
        try await host.waitForVisible("Lower extension")
        let lowerComponent = host.tui.getFocusedComponent()
        let selector = T1SelectorProbe()
        var selectorDone: (() -> Void)?
        host.mode.showSelector { done in
            selectorDone = done
            return (component: selector, focus: selector)
        }
        try await host.waitForVisible("built-in selector")
        let top = T1DialogResult { await ui.confirm("Top extension", "private") }
        try await host.waitForVisible("Top extension")
        let topComponent = host.tui.getFocusedComponent()
        #expect(selector.closeCount == 1)
        selectorDone?()
        #expect(host.tui.getFocusedComponent() === topComponent)
        #expect(host.visible.contains("Top extension"))
        host.tui.getFocusedComponent()?.handleInput("\u{1B}")
        #expect(try await top.value() == false)
        try await host.waitForVisible("Lower extension")
        #expect(host.tui.getFocusedComponent() === lowerComponent)
        selectorDone?()
        #expect(host.tui.getFocusedComponent() === lowerComponent)
        #expect(!lower.completed)
        host.tui.getFocusedComponent()?.handleInput("\r")
        #expect(try await lower.value())
        selectorDone?()
        #expect(selector.closeCount == 1)
        host.expectEditor()
    }

    @Test(arguments: T1DialogEnd.allCases)
    func hostResetReloadAndShutdownSettleAllDialogsAndPendingFactories(_ end: T1DialogEnd) async throws {
        let host = T1DialogHost()
        defer { host.close() }
        await host.start()
        host.editor.setText("saved draft")
        var results: [T1DialogResult<String?>] = []
        var probes: [T1DialogProbe] = []
        for kind in T1DialogKind.allCases {
            let probe = T1DialogProbe("\(end.rawValue) \(kind.rawValue)")
            probes.append(probe)
            results.append(host.open(kind, probe.label, probe: probe))
            if kind == .overlay { try await t1WaitUntil { probe.focused } }
            else { try await host.waitForVisible(probe.label) }
        }
        let lateInline = T1DialogProbe("late inline")
        let lateOverlay = T1DialogProbe("late overlay")
        let inlineGate = T1FactoryGate()
        let overlayGate = T1FactoryGate()
        defer { inlineGate.release(); overlayGate.release() }
        let pendingInline = host.openCustom(lateInline, gate: inlineGate)
        try await t1WaitUntil { inlineGate.entered }
        let pendingOverlay = host.openCustom(lateOverlay, overlay: true, gate: overlayGate)
        try await t1WaitUntil { overlayGate.entered }

        switch end {
        case .reset: host.mode.resetExtensionDialogs()
        case .reload: await host.mode.handleReloadCommand()
        case .shutdown: await host.mode.performShutdown()
        }

        for result in results { #expect(try await result.value() == nil) }
        #expect(try await pendingInline.value() == nil)
        #expect(try await pendingOverlay.value() == nil)
        #expect(!host.tui.hasOverlay())
        host.expectEditor()
        #expect(host.editor.getText() == "saved draft")
        #expect(host.reports.last?.state != .blocked)
        for probe in probes where probe.close != nil {
            probe.close?("late callback")
            #expect(probe.disposeCount == 1)
        }

        inlineGate.release()
        overlayGate.release()
        try await t1WaitUntil { lateInline.disposeCount == 1 && lateOverlay.disposeCount == 1 }
        lateInline.close?("late callback")
        lateOverlay.close?("late callback")
        #expect(lateInline.disposeCount == 1)
        #expect(lateOverlay.disposeCount == 1)
        #expect(!host.tui.hasOverlay())
        host.expectEditor()
    }
}
