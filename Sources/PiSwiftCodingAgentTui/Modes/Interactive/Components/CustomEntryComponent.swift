import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Presents a persisted display-only extension entry. These entries intentionally never
/// pass through the agent's model context; they are rendered from `SessionManager` only.
public final class CustomEntryComponent: Container, OutputPaddingSetting {
    private let entry: CustomEntry
    private let renderer: EntryRenderer?
    private var renderedComponent: Component?
    private var expanded = false
    private var outputPad: Int

    public init(entry: CustomEntry, renderer: EntryRenderer?, outputPad: Int = 1) {
        self.entry = entry
        self.renderer = renderer
        self.outputPad = outputPad
        super.init()
        rebuild()
    }

    public func setOutputPad(_ outputPad: Int) {
        self.outputPad = outputPad
        rebuild()
    }

    public func setExpanded(_ expanded: Bool) {
        guard self.expanded != expanded else { return }
        self.expanded = expanded
        rebuild()
    }

    public override func invalidate() {
        super.invalidate()
        rebuild()
    }

    private func rebuild() {
        if let renderedComponent {
            removeChild(renderedComponent)
            self.renderedComponent = nil
        }
        guard let renderer,
              let component = renderer(entry, EntryRenderOptions(expanded: expanded), theme) as? Component
        else {
            return
        }
        renderedComponent = component
        addChild(component)
    }
}
