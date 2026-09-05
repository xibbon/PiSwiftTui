import Foundation
import MiniTui
import PiSwiftCodingAgent

@MainActor
public final class WorkingStatusIndicator: Loader {
    public init(ui: TUI, message: String = "Working", indicator: LoaderIndicatorOptions? = nil,
                colorFn: ((String) -> String)? = nil) {
        super.init(ui: ui,
                   spinnerColorFn: colorFn ?? { theme.fg(.accent, $0) },
                   messageColorFn: colorFn ?? { theme.fg(.muted, $0) }, message: message)
        if let indicator { setIndicator(indicator) }
    }

    public func dispose() { stop() }

    public func renderInBorder(width: Int) -> String {
        let lines = super.render(width: width + 2)
        var line = lines.count > 1 ? lines[1] : ""
        if line.hasPrefix(" ") { line.removeFirst() }
        while line.last?.isWhitespace == true { line.removeLast() }
        return truncateToWidth(line, maxWidth: width, ellipsis: "")
    }

    public func renderSpinnerInBorder(width: Int) -> String {
        truncateToWidth(getRenderedIndicator(), maxWidth: width, ellipsis: "")
    }
}
