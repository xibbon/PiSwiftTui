import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentTui

@MainActor
@Suite(.serialized)
struct T2ToolImageTests {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII="
    private let jpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAGCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AD3VTB3/2Q=="

    private func row() -> ToolExecutionComponent {
        ToolExecutionComponent(toolName: "tool", toolCallId: "id", args: [:], ui: TUI(terminal: ToolTestTerminal()))
    }

    private func result(_ sources: [(String, String)]) -> ToolResultMessage {
        ToolResultMessage(toolCallId: "id", toolName: "tool", content: sources.map {
            .image(ImageContent(data: $0.0, mimeType: $0.1))
        }, isError: false)
    }

    private func rendered(_ component: ToolExecutionComponent) -> String {
        component.render(width: 120).joined(separator: "\n")
    }

    private func imageIDs(_ output: String) -> [Int] {
        output.components(separatedBy: "\u{001B}_G").dropFirst().compactMap { sequence in
            let controls = sequence.prefix { $0 != ";" }
            return controls.split(separator: ",").first { $0.hasPrefix("i=") }.flatMap { Int($0.dropFirst(2)) }
        }
    }

    private func restore(_ capabilities: TerminalCapabilities) {
        setImageTranscoder(nil)
        pngTranscoderRegistered = false
        setCapabilities(capabilities)
    }

    #if canImport(AppKit)
    // Issues #10292 and #8577: the host loads its converter; a final image replaces partial data.
    @Test("converts non-PNG tool images once the transcoder loads")
    func convertsNonPngToolImages() {
        let saved = getCapabilities()
        defer { restore(saved) }
        setImageTranscoder(nil)
        pngTranscoderRegistered = false
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true))
        let component = row()
        component.updateResult(result([("cGFydGlhbA==", "image/jpeg")]), isPartial: true)
        component.updateResult(result([(jpeg, "image/jpeg")]))
        let output = rendered(component)
        #expect(output.contains(";iVBORw0KGgo"))
        #expect(!output.contains("cGFydGlhbA=="))
        #expect(imageIDs(output).count == 1)
        component.invalidate()
        #expect(rendered(component) == output)
    }
    #endif

    @Test("reuses each image at its index until data, MIME type, or width changes")
    func reusesImageSources() {
        let saved = getCapabilities()
        defer { restore(saved) }
        pngTranscoderRegistered = false
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true))
        ensurePngTranscoder()
        var conversions = 0
        setImageTranscoder { _, _ in
            conversions += 1
            return self.png
        }
        let component = row()
        component.updateResult(result([("first", "image/jpeg"), ("second", "image/webp")]))
        let initialIDs = imageIDs(rendered(component))
        #expect(initialIDs.count == 2)
        #expect(conversions == 2)
        component.invalidate()
        component.setExpanded(true)
        component.updateResult(result([("first", "image/jpeg"), ("second", "image/webp")]))
        #expect(imageIDs(rendered(component)) == initialIDs)
        #expect(conversions == 2)
        component.updateResult(result([("replacement", "image/jpeg"), ("second", "image/webp")]))
        let replacedIDs = imageIDs(rendered(component))
        #expect(replacedIDs.count == 2)
        #expect(replacedIDs.first != initialIDs.first)
        #expect(replacedIDs.last == initialIDs.last)
        #expect(conversions == 3)
        component.updateResult(result([("replacement", "image/gif"), ("second", "image/webp")]))
        let changedMimeIDs = imageIDs(rendered(component))
        #expect(changedMimeIDs.first != replacedIDs.first)
        #expect(changedMimeIDs.last == replacedIDs.last)
        component.setImageWidthCells(20)
        let resizedIDs = imageIDs(rendered(component))
        #expect(resizedIDs.count == 2)
        #expect(zip(resizedIDs, changedMimeIDs).allSatisfy { $0.0 != $0.1 })
        #expect(conversions == 3)
    }

    @Test("shows a text fallback for a non-PNG image that cannot be converted on Kitty")
    func failedConversionShowsFallback() {
        let saved = getCapabilities()
        defer { restore(saved) }
        setImageTranscoder(nil)
        pngTranscoderRegistered = false
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true))
        let component = row()
        component.updateResult(result([("bm90IGFuIGltYWdl", "image/jpeg")]))
        for _ in 0..<2 {
            let output = toolTestText(component)
            #expect(output.components(separatedBy: "image/jpeg").count - 1 == 1)
            #expect(imageIDs(rendered(component)).isEmpty)
            component.invalidate()
        }
    }

    @Test("registers the PNG transcoder only once and only for Kitty")
    func registrationUsesKittyOnce() {
        let saved = getCapabilities()
        defer { restore(saved) }
        setImageTranscoder(nil)
        pngTranscoderRegistered = false
        setCapabilities(TerminalCapabilities(images: .iterm2, trueColor: true, hyperlinks: true))
        ensurePngTranscoder()
        #expect(!pngTranscoderRegistered)
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true))
        ensurePngTranscoder()
        #expect(pngTranscoderRegistered)
        var conversions = 0
        setImageTranscoder { _, _ in
            conversions += 1
            return self.png
        }
        ensurePngTranscoder()
        let component = row()
        component.updateResult(result([("source", "image/jpeg")]))
        #expect(rendered(component).contains(";iVBORw0KGgo"))
        #expect(conversions == 1)
    }
}
