import MiniTui

/// Build text with the current theme after each invalidation.
/// Save changing data before you create the component.
open class ThemedText: Text {
    private let build: () -> String
    private var stale = true

    public init(_ build: @escaping () -> String, paddingX: Int = 1, paddingY: Int = 1) {
        self.build = build
        super.init("", paddingX: paddingX, paddingY: paddingY)
    }

    public override func invalidate() {
        super.invalidate()
        stale = true
    }

    public override func render(width: Int) -> [String] {
        if stale {
            setText(build())
            // MiniTui.setText calls invalidate, so clear this flag after setText.
            stale = false
        }
        return super.render(width: width)
    }
}

public final class ExpandableText: ThemedText {
    private final class State {
        var expanded: Bool
        init(_ expanded: Bool) { self.expanded = expanded }
    }
    private let state: State

    public init(collapsed: @escaping () -> String, expanded: @escaping () -> String,
                isExpanded: Bool = false, paddingX: Int = 0, paddingY: Int = 0) {
        let state = State(isExpanded)
        self.state = state
        super.init({ state.expanded ? expanded() : collapsed() }, paddingX: paddingX, paddingY: paddingY)
    }

    public func setExpanded(_ expanded: Bool) {
        state.expanded = expanded
        invalidate()
    }
}
