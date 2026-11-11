import Foundation
import MiniTui
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

private struct MermaidFixture: Decodable {
    let header: String
    let cases: [Case]
    struct Case: Decodable {
        let name: String
        let source: String
        let widths: [Width]
        let warnings: [String]
        let authorColors: AuthorColors?
        struct AuthorColors: Decodable {
            let border: String?
            let text: String?
        }
        struct Width: Decodable {
            let width: Int
            let output: [String]?
            let markdown: String
            let themedUnlinked: String
            let themedTruecolor: String
        }
    }
}

@Test func pt2ClassColorFormsMatchLovelyMermaid() throws {
    let fixture = try loadMermaidFixture()
    let plainSource = mermaidMarkdown("flowchart LR\n  A[Hot] --> B[Plain]")
    for item in fixture.cases where item.name.hasPrefix("style") {
        let reference = try #require(item.widths.first { $0.width == 80 })
        let source = mermaidMarkdown(item.source)
        for mode in [PiSwiftCodingAgent.TerminalColorMode.color256, .truecolor] {
            let selectedTheme = try #require(getThemeByName("dark", mode: mode))
            let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(theme: selectedTheme))
            let rendered = transform(source, 80)
            if let colors = item.authorColors {
                if let border = colors.border, border.hasPrefix("38;2;") {
                    let code = "\u{1B}[\(border)m"
                    #expect(reference.themedUnlinked.contains(code))
                    #expect(reference.themedTruecolor.contains(code))
                    #expect(rendered.contains(code + "┌"))
                }
                if let text = colors.text, text.hasPrefix("38;2;") {
                    let code = "\u{1B}[\(text)m"
                    #expect(reference.themedUnlinked.contains(code))
                    #expect(reference.themedTruecolor.contains(code))
                    #expect(rendered.contains(code + "Hot"))
                }
            } else {
                #expect(!reference.themedUnlinked.contains("48;2;"))
                #expect(!reference.themedTruecolor.contains("48;2;"))
                #expect(rendered == transform(plainSource, 80))
            }
        }
    }
    #expect(parseMermaidClassColor("#f9f") == MermaidRGB(red: 255, green: 153, blue: 255))
    #expect(parseMermaidClassColor("#ff9999") == MermaidRGB(red: 255, green: 153, blue: 153))
    #expect(parseMermaidClassColor("red") == MermaidRGB(red: 255, green: 0, blue: 0))
    #expect(parseMermaidClassColor("rgb(0,0,0)") == MermaidRGB(red: 0, green: 0, blue: 0))
    #expect(parseMermaidClassColor("rgba(0,0,0,0.5)") == MermaidRGB(red: 0, green: 0, blue: 0))
    #expect(parseMermaidClassColor("#f9fa") == nil)
    #expect(parseMermaidClassColor("#ff9999aa") == nil)
}

private func loadMermaidFixture() throws -> MermaidFixture {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MermaidLovely033.json")
    return try JSONDecoder().decode(MermaidFixture.self, from: Data(contentsOf: url))
}

private func mermaidMarkdown(_ source: String) -> String { "```mermaid\n\(source)\n```" }

@Test func pt2PieMatchesLovelyMermaidCellsAtThreeWidths() throws {
    let fixture = try loadMermaidFixture()
    #expect(fixture.header.contains("lovely-mermaid@0.3.3"))
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions())
    for item in fixture.cases where item.name.hasPrefix("pie") {
        for result in item.widths {
            let source = mermaidMarkdown(item.source)
            let rendered = transform(source, result.width)
            if let lines = result.output {
                #expect(rendered == result.markdown, "\(item.name) at \(result.width)")
                #expect(result.markdown.contains(lines[0]))
            } else {
                #expect(rendered == source, "\(item.name) at \(result.width)")
            }
        }
    }
}

@MainActor @Suite(.serialized) struct PT2MermaidCapabilityTests {
    @Test func clickLinksOnlyTheLabelWhenCapabilityAllowsIt() {
        let original = getCapabilities()
        defer { setCapabilities(original) }
        let source = mermaidMarkdown("flowchart TD\n  A[Docs] --> B[Done]\n  click A \"https://example.com/docs\"")
        let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(theme: .fallback()))
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true))
        let linked = transform(source, 80)
        #expect(linked.contains("\u{1B}]8;;https://example.com/docs\u{1B}\\"))
        #expect(linked.components(separatedBy: "\u{1B}]8;;https://example.com/docs\u{1B}\\").count == 2)
        let href = mermaidMarkdown("flowchart TD\n  A[Docs] --> B[Done]\n  click A href \"https://example.com/docs\"")
        #expect(transform(href, 80).contains("\u{1B}]8;;https://example.com/docs\u{1B}\\"))
        let markdownLabel = mermaidMarkdown("flowchart LR\n  A[\"[Docs](https://example.com)\"] --> B[Done]")
        #expect(!transform(markdownLabel, 120).contains("\u{1B}]8;;"))
        setCapabilities(TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false))
        let plain = transform(source, 80)
        #expect(!plain.contains("\u{1B}]8;;"))
        #expect(!plain.contains("https://example.com/docs"))
    }
}

@Test func pt2FlowStylesAndWarningFallback() {
    let theme = Theme.fallback()
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(theme: theme))
    let styled = mermaidMarkdown("flowchart LR\n  A[Hot]:::highlight --> B[Plain]\n  classDef highlight fill:#f96,stroke:#333,color:#000,font-weight:bold")
    let output = transform(styled, 80)
    #expect(output.contains("\u{1B}[1;38;2;51;51;51;48;2;255;153;102m"))
    #expect(output.contains("\u{1B}[1;38;2;0;0;0;48;2;255;153;102m"))
    let broken = mermaidMarkdown("flowchart LR\n  A --> B\n  broken !")
    let final = transform(broken, 80)
    #expect(final.contains(broken))
    #expect(final.contains("dropped, expected a link: \"!\""))
    let streaming = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(isStreaming: true))
    #expect(streaming(broken, 80).contains("│ broken │"))
    // lovely-mermaid 0.3.3 accepts these declarations but does not paint them.
    let direct = mermaidMarkdown("flowchart LR\n  A[Hot] --> B\n  style A fill:#f96\n  linkStyle 0 stroke:#f00")
    let unstyled = mermaidMarkdown("flowchart LR\n  A[Hot] --> B")
    #expect(transform(direct, 80) == transform(unstyled, 80))
}

@Test func pt2WarningsMatchReferenceAtThreeWidths() throws {
    let fixture = try loadMermaidFixture()
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions())
    for item in fixture.cases where item.name == "flowBad" || item.name == "flowBadTwo" {
        for width in [40, 80, 120] {
            let source = mermaidMarkdown(item.source)
            let reference = item.widths.first { $0.width == width }
            #expect(transform(source, width) == reference?.markdown)
        }
        if item.name == "flowBad" {
            #expect(transform(mermaidMarkdown(item.source) + "\nFollowing text", 80).contains("  \nFollowing text"))
        }
    }
}

@Test func pt2ExistingBasicFlowMatchesReference() throws {
    let fixture = try loadMermaidFixture()
    let item = try #require(fixture.cases.first { $0.name == "flowBasic" })
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions())
    for width in item.widths {
        #expect(transform(mermaidMarkdown(item.source), width.width) == width.markdown)
    }
}

@Test func pt2RenderingModesAndIncompleteBlock() {
    let complete = mermaidMarkdown("flowchart LR\n  A --> B")
    let off = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(enabled: false))
    #expect(off(complete, 80) == complete)
    let finalOnly = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(
        renderWhileStreaming: false, isStreaming: true))
    #expect(finalOnly(complete, 80) == complete)
    let final = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(
        renderWhileStreaming: false))
    #expect(!final(complete, 80).contains("```mermaid"))
    let partial = "```mermaid\nflowchart LR\n  A --> B"
    let streaming = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions(isStreaming: true))
    #expect(streaming(partial, 80).contains("───▶"))
    #expect(final(partial, 80) == partial)
}

@MainActor @Test func pt2UserAndSummarySurfacesRenderMermaid() {
    let source = mermaidMarkdown("pie\n  title Pets\n  \"Dogs\" : 4")
    let user = UserMessageComponent(text: source)
    #expect(user.render(width: 80).joined(separator: "\n").contains("████████████████████"))
    let branch = BranchSummaryMessageComponent(message: BranchSummaryMessage(summary: source, fromId: "1", timestamp: 0))
    branch.setExpanded(true)
    #expect(branch.render(width: 80).joined(separator: "\n").contains("████████████████████"))
    let compaction = CompactionSummaryMessageComponent(message: CompactionSummaryMessage(summary: source, tokensBefore: 100, timestamp: 0))
    compaction.setExpanded(true)
    #expect(compaction.render(width: 80).joined(separator: "\n").contains("████████████████████"))
}

@Test func pt2UnsupportedDiagramTypesFallBack() throws {
    let fixture = try loadMermaidFixture()
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions())
    for item in fixture.cases where ["sequence", "class", "state", "er", "timeline", "mindmap", "gitgraph", "gantt"].contains(item.name) {
        let source = mermaidMarkdown(item.source)
        #expect(transform(source, 120) == source)
    }
}
