import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor @Suite(.serialized) struct PT1DiffTests {
    // pi-mono v1.5.2 packages/coding-agent/test/diff.test.ts:9–33.
    @Test(arguments: [
        "-83   await commitRecordingChunk({\n+83   const result = await commitRecordingChunk({",
        "-12     const value = oldValue\n+12     const value = newValue",
    ]) func preservesIndentation(_ diff: String) {
        #expect(toolTestPlain(renderDiff(diff)) == diff)
    }

    @Test func sharedIndentationIsNotHighlightedAsAnInsertion() throws {
        let rendered = renderDiff("-83   await commitRecordingChunk({\n+83   const result = await commitRecordingChunk({")
        let insertion = theme.inverse("const result = ")
        let prefix = try #require(rendered.range(of: "+83   "))
        let changed = try #require(rendered.range(of: insertion))
        #expect(prefix.lowerBound < changed.lowerBound)
    }

    @Test func multipleLineChangesAndWindowMarkersKeepTheirText() {
        let diff = "-100 old\n-101 other\n+100 new\n+101 next\n    ...\n 900 \tcontext"
        #expect(toolTestPlain(renderDiff(diff)) == diff.replacingOccurrences(of: "\t", with: "   "))
        #expect(!renderDiff(diff).contains("\u{1b}[7m"))
    }
}
