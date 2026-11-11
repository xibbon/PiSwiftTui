import Foundation
import MiniTui
import Testing
@testable import PiSwiftCodingAgentTui

private struct PT2Random {
    var state: UInt64 = 0x8158_11875_11592
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Test func pt2MermaidSeededFuzzTwentyThousandInputs() {
    let corpus = [
        "pie\n  title Pets\n  \"Dogs\" : 4",
        "pie showData\n  \"Books\" : 3\n  \"Games\" : 2",
        "pie\n  \"A\" : 0.25\n  \"B\" : 0.75",
        "flowchart LR\n  A[Start] --> B[Done]",
        "flowchart TD\n  A[Docs] --> B[Done]\n  click A \"https://example.com\"",
        "flowchart LR\n  A[Hot]:::hot --> B\n  classDef hot fill:#f96",
        "sequenceDiagram\n  Alice->>Bob: Hello",
        "classDiagram\n  Animal <|-- Dog",
        "stateDiagram-v2\n  [*] --> Open",
        "gantt\n  title Plan",
    ]
    var inputs: [String] = []
    for source in corpus {
        let bytes = Array(source.utf8)
        for end in 0...bytes.count { inputs.append(String(decoding: bytes.prefix(end), as: UTF8.self)) }
    }
    inputs.append("pie\n" + (0..<10_000).map { "\"Slice \($0)\" : 1" }.joined(separator: "\n"))
    inputs.append("pie\n\"\(String(repeating: "x", count: 40_000))\" : 1")
    inputs.append("flowchart TD\n" + (0..<500).map { _ in "subgraph nested" }.joined(separator: "\n"))
    inputs.append("pie\n\"\u{1B}[31m\u{0000}\u{007F}\" : 1")
    inputs.append(String(decoding: [0xD800, 0x0020, 0xDC00] as [UInt16], as: UTF16.self))
    var random = PT2Random()
    let alphabet = Array("pie\nflowchart LR TD A B [ ] ( ) { } --> ::: classDef style click \" : 0123456789!?\u{1B}")
    while inputs.count < 20_000 {
        var source = corpus[Int(random.next() % UInt64(corpus.count))]
        let count = Int(random.next() % 12) + 1
        for _ in 0..<count {
            let characters = Array(source)
            let position = Int(random.next() % UInt64(characters.count + 1))
            let replacement = alphabet[Int(random.next() % UInt64(alphabet.count))]
            source = String(characters.prefix(position)) + String(replacement) + String(characters.dropFirst(position + (position < characters.count ? 1 : 0)))
        }
        inputs.append(source)
    }
    let transform = createMermaidMarkdownTransform(options: MermaidMarkdownTransformOptions())
    let started = Date().timeIntervalSinceReferenceDate
    var slowest = 0.0
    for (index, input) in inputs.enumerated() {
        let width = [40, 80, 120][index % 3]
        let markdown = "```mermaid\n\(input)\n```"
        let singleStart = Date().timeIntervalSinceReferenceDate
        let output = transform(markdown, width)
        let elapsed = Date().timeIntervalSinceReferenceDate - singleStart
        slowest = max(slowest, elapsed)
        #expect(elapsed < 1.0)
        if output != markdown && !output.contains("Mermaid diagram not rendered:") {
            for rawLine in output.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                if !line.hasPrefix("Mermaid diagram not rendered:") && !line.hasPrefix("```mermaid") {
                    #expect(visibleWidth(line) <= width)
                }
            }
        }
    }
    print("PT2 Mermaid fuzz: \(inputs.count) inputs, total \(Date().timeIntervalSinceReferenceDate - started)s, slowest \(slowest)s, bound 1.0s")
}
