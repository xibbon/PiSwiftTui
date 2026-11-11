import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

/// Keep the source text in session state. Extensions transform it only for display.
func hostMarkdownTransform(
    runner: HookRunner?,
    type: MarkdownMessageType,
    isStreaming: Bool = false,
    streamingState: LockedState<Bool>? = nil,
    messageId: String? = nil,
    timestamp: String? = nil
) -> MarkdownSourceTransform? {
    guard let runner else { return nil }
    return { source, width in
        runner.transformMarkdown(source, context: MarkdownTransformContext(
            messageType: type, isStreaming: streamingState?.withLock { $0 } ?? isStreaming, availableWidth: width,
            messageId: messageId, timestamp: timestamp))
    }
}

func hostPrefixedMarkdownTransform(
    runner: HookRunner?, type: MarkdownMessageType, header: String,
    messageId: String?, timestamp: String?
) -> MarkdownSourceTransform? {
    guard let transform = hostMarkdownTransform(runner: runner, type: type,
        messageId: messageId, timestamp: timestamp) else { return nil }
    return { source, width in
        guard source.hasPrefix(header) else { return source }
        return header + transform(String(source.dropFirst(header.count)), width)
    }
}
