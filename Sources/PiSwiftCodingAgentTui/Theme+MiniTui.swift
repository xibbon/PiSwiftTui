import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftSyntaxHighlight

extension EditorTheme: HookEditorTheme {}

public extension MiniTui.RgbColor {
    var codingAgentColor: PiSwiftCodingAgent.RgbColorValue {
        // The terminal parser supplies validated 8-bit channels.
        PiSwiftCodingAgent.colorToRgb(try! PiSwiftCodingAgent.rgbColor(Double(r), Double(g), Double(b)))
    }
}

public extension MiniTui.TerminalColors {
    var codingAgentColors: PiSwiftCodingAgent.TerminalColors {
        PiSwiftCodingAgent.TerminalColors(
            foreground: foreground?.codingAgentColor,
            background: background?.codingAgentColor,
            palette: palette?.map { $0.codingAgentColor }
        )
    }
}

public extension MiniTui.TerminalColorMode {
    var codingAgentColorMode: PiSwiftCodingAgent.TerminalColorMode {
        switch self {
        case .truecolor: .truecolor
        case .color256: .color256
        }
    }
}

public extension MiniTui.TerminalColorScheme {
    var codingAgentAppearance: ThemeAppearance { self == .light ? .light : .dark }
}

public func highlightCode(_ code: String, lang: String? = nil) -> [String] {
    let adapter = ThemeSyntaxAdapter(theme: theme)
    return SyntaxHighlighter.highlight(code: code, lang: lang, theme: adapter)
}

private struct ThemeSyntaxAdapter: SyntaxTheme {
    let theme: Theme

    func plain(_ text: String) -> String { theme.fg(.mdCodeBlock, text) }
    func keyword(_ text: String) -> String { theme.fg(.syntaxKeyword, text) }
    func builtIn(_ text: String) -> String { theme.fg(.syntaxType, text) }
    func literal(_ text: String) -> String { theme.fg(.syntaxNumber, text) }
    func number(_ text: String) -> String { theme.fg(.syntaxNumber, text) }
    func string(_ text: String) -> String { theme.fg(.syntaxString, text) }
    func comment(_ text: String) -> String { theme.fg(.syntaxComment, text) }
    func function(_ text: String) -> String { theme.fg(.syntaxFunction, text) }
    func type(_ text: String) -> String { theme.fg(.syntaxType, text) }
    func variable(_ text: String) -> String { theme.fg(.syntaxVariable, text) }
    func operatorToken(_ text: String) -> String { theme.fg(.syntaxOperator, text) }
    func punctuation(_ text: String) -> String { theme.fg(.syntaxPunctuation, text) }
}

public func getMarkdownTheme() -> MarkdownTheme {
    MarkdownTheme(
        heading: { theme.fg(.mdHeading, $0) },
        link: { theme.fg(.mdLink, $0) },
        linkUrl: { theme.fg(.mdLinkUrl, $0) },
        code: { theme.fg(.mdCode, $0) },
        codeBlock: { theme.fg(.mdCodeBlock, $0) },
        codeBlockBorder: { theme.fg(.mdCodeBlockBorder, $0) },
        quote: { theme.fg(.mdQuote, $0) },
        quoteBorder: { theme.fg(.mdQuoteBorder, $0) },
        hr: { theme.fg(.mdHr, $0) },
        listBullet: { theme.fg(.mdListBullet, $0) },
        bold: { theme.bold($0) },
        italic: { theme.italic($0) },
        strikethrough: { theme.strikethrough($0) },
        underline: { theme.underline($0) },
        highlightCode: { code, lang in
            highlightCode(code, lang: lang)
        }
    )
}

public func getSelectListTheme() -> SelectListTheme {
    SelectListTheme(
        selectedPrefix: { theme.fg(.accent, $0) },
        selectedText: { theme.fg(.accent, $0) },
        description: { theme.fg(.muted, $0) },
        scrollInfo: { theme.fg(.muted, $0) },
        noMatch: { theme.fg(.muted, $0) },
        selectedBackground: { theme.bg(.selectedBg, $0) }
    )
}

public func getEditorTheme() -> EditorTheme {
    EditorTheme(borderColor: { theme.fg(.borderMuted, $0) }, selectList: getSelectListTheme())
}

public func getSettingsListTheme() -> SettingsListTheme {
    SettingsListTheme(
        label: { text, selected in selected ? theme.fg(.accent, text) : text },
        value: { text, selected in selected ? theme.fg(.accent, text) : theme.fg(.muted, text) },
        description: { theme.fg(.dim, $0) },
        cursor: theme.fg(.accent, "→ "),
        hint: { theme.fg(.dim, $0) }
    )
}
