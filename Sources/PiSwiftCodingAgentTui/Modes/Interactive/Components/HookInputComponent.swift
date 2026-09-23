import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class HookInputComponent: Container, SystemCursorAware {
    private let input: Input
    private let onSubmitCallback: (String) -> Void
    private let onCancelCallback: () -> Void
    public var usesSystemCursor: Bool {
        get { input.usesSystemCursor }
        set { input.usesSystemCursor = newValue }
    }

    public init(
        title: String,
        placeholder: String? = nil,
        description: String? = nil,
        initialValue: String? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmitCallback = onSubmit
        self.onCancelCallback = onCancel
        self.input = Input()
        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, title), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        if let description, !description.isEmpty {
            addChild(Text(theme.fg(.dim, description), paddingX: 1, paddingY: 0))
            addChild(Spacer(1))
        }

        if let value = initialValue ?? placeholder {
            input.setValue(value)
        }
        addChild(input)

        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "enter submit  esc cancel"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())
    }

    public override func handleInput(_ keyData: String) {
        if isEnter(keyData) || keyData == "\n" {
            onSubmitCallback(input.getValue())
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
            return
        }
        input.handleInput(keyData)
    }
}
