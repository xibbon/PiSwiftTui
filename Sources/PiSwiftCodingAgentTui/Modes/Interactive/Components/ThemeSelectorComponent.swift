import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class ThemeSelectorComponent: Container {
    private let selectList: SelectList
    private let onPreview: (String) -> Void

    public init(
        currentTheme: String,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onPreview: @escaping (String) -> Void
    ) {
        self.onPreview = onPreview

        let themes = getAvailableThemes()
        let items = themes.map { name in
            SelectItem(value: name, label: (name == currentTheme ? "✓ " : "  ") + name)
        }
        self.selectList = SelectList(items: items, maxVisible: 10, theme: getSelectListTheme())

        super.init()

        addChild(DynamicBorder())

        if let idx = themes.firstIndex(of: currentTheme) {
            selectList.setSelectedIndex(idx)
        }

        selectList.onSelect = { item in
            onSelect(item.value)
        }
        selectList.onCancel = onCancel
        selectList.onSelectionChange = { [weak self] item in
            self?.onPreview(item.value)
        }

        addChild(selectList)
        addChild(DynamicBorder())
    }

    public func getSelectList() -> SelectList {
        selectList
    }
}
