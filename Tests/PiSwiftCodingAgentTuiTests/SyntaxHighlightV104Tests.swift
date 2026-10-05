import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentTui

// Adapted from pi-mono v1.0.4 syntax-highlight.test.ts:99-114 (#10143, b9ab918c6). Swift colors
// plain code with mdCodeBlock, where upstream leaves it unstyled for a known language.
@Test func syntaxHighlightColorsEachPythonDocstringLine() {
    initTheme("dark")
    let code = "\"\"\"\nline one\n\nline two\n\"\"\"\nafter"
    let expected = [
        theme.fg(.syntaxString, "\"\"\""),
        theme.fg(.syntaxString, "line one"),
        "",
        theme.fg(.syntaxString, "line two"),
        theme.fg(.syntaxString, "\"\"\""),
        theme.fg(.mdCodeBlock, "after"),
    ]

    #expect(PiSwiftCodingAgentTui.highlightCode(code, lang: "python") == expected)
    #expect(getMarkdownTheme().highlightCode?(code, "python") == expected)
}
