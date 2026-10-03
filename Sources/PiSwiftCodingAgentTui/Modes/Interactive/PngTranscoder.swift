import MiniTui
import PiSwiftCodingAgent

@MainActor
var pngTranscoderRegistered = false

/// Register the PNG converter once for terminals that use the Kitty protocol.
@MainActor
func ensurePngTranscoder() {
    guard !pngTranscoderRegistered, getCapabilities().images == .kitty else { return }
    setImageTranscoder { transcodeToPng($0, $1) }
    pngTranscoderRegistered = true
}
