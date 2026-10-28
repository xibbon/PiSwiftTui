import Foundation
import MiniTui
import PiSwiftCodingAgent

@MainActor
struct ExtensionDialog {
    let id: UUID
    let component: Component
    let blocked: BlockedStatus?
    let cancel: () -> Void
}

@MainActor
struct ExtensionDialogOverlay {
    let id: UUID
    let component: Component
    let handle: HookOverlayHandle
    let options: OverlayOptions?
}

/// The cancellation handler and component callbacks share one completion operation.
@MainActor
final class ExtensionDialogWait<Value: Sendable> {
    let id = UUID()
    var component: Component?
    var overlayHandle: HookOverlayHandle?
    var beforeFinish: (() -> Void)?
    var completion: ((Value?) -> Void)?
    private(set) var completed = false

    func finish(_ value: Value?) {
        guard !completed else { return }
        completed = true
        let beforeFinish = beforeFinish
        self.beforeFinish = nil
        beforeFinish?()
        let completion = completion
        self.completion = nil
        completion?(value)
    }
}
