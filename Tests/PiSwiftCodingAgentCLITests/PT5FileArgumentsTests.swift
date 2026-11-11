import Foundation
import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

// v1.5.2 PT5: file-processor.ts:47-67 and utils/image-process.ts:47-100.
struct PT5FileArgumentsTests {
    @Test func rawBmpWithoutAutoResizeBecomesPngWithNote() throws {
        // One 24-bit pixel, with a four-byte row and the standard 54-byte BMP header.
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 0x42
        bytes[1] = 0x4d
        bytes[2] = 58
        bytes[10] = 54
        bytes[14] = 40
        bytes[18] = 1
        bytes[22] = 1
        bytes[26] = 1
        bytes[28] = 24
        bytes[34] = 4
        bytes[56] = 0xff
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pt5-bmp-\(UUID().uuidString).bmp")
        try Data(bytes).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        var args = Args()
        args.fileArgs = [path.path]
        let result = try prepareInitialMessage(&args, autoResizeImages: false,
                                               blockImages: false, resizeOptions: nil)
        #expect(result.message?.contains("[Image converted from image/bmp to image/png.]") == true)
        let image = try #require(result.images?.first)
        #expect(image.mimeType == "image/png")
        let data = try #require(Data(base64Encoded: image.data))
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }
}
