import SwiftUI

/// macOS 27 lays a grouped Form (any SwiftUI scroll container) out 430 pt wide
/// for one pass when its state changes *inside* a mouse event on one of its
/// controls, overflowing the 340 pt sidebar until the next update (GitHub #2).
/// The same change made a run-loop turn later is laid out correctly, so every
/// state write that starts in a mouse event, a drop or a menu command goes
/// through here (or `deferredLive` below): the panel controls, the crop drag, drops,
/// the open panel, file-open Apple events, the Save commands and Settings.
@MainActor func deferred(_ work: @escaping @MainActor () -> Void) {
    // Two hops, both needed (measured on macOS 27.0):
    // 1. A default-mode run-loop block, not DispatchQueue.main.async: the main
    //    queue also drains while a drag session or a modal panel spins the run
    //    loop in its tracking mode, and that still counts as inside the event.
    // 2. From there, one more turn through the main actor: the block itself
    //    runs while AppKit is still settling the window (a panel closing, a
    //    drag ending), and a state change right then still hits the bug.
    let box = MainThreadBox(work)
    RunLoop.main.perform(inModes: [.default]) {
        Task { @MainActor in box.value() }
    }
}

/// For continuous interactions (the crop drag, sliders). While the mouse is
/// held they run the run loop in its event-tracking mode, where `deferred`
/// would hold every update until the release. A main-queue hop still runs
/// during tracking, and for these it is enough to keep the sidebar at 340.
@MainActor func deferredLive(_ work: @escaping @MainActor () -> Void) {
    let box = MainThreadBox(work)
    DispatchQueue.main.async { MainActor.assumeIsolated { box.value() } }
}

/// Carries a non-Sendable value to the run-loop callback; both ends run on the main thread.
private final class MainThreadBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension Binding {
    /// Writes on the next default-mode run-loop turn; see `deferred(_:)`.
    var deferred: Binding<Value> {
        let base = MainThreadBox(self)
        return Binding(get: { base.value.wrappedValue }, set: { new in
            let box = MainThreadBox(new)
            RunLoop.main.perform(inModes: [.default]) {
                Task { @MainActor in base.value.wrappedValue = box.value }
            }
        })
    }

    /// Writes on the next main-queue turn; see `deferredLive(_:)`.
    var deferredLive: Binding<Value> {
        let base = MainThreadBox(self)
        return Binding(get: { base.value.wrappedValue }, set: { new in
            let box = MainThreadBox(new)
            DispatchQueue.main.async { MainActor.assumeIsolated { base.value.wrappedValue = box.value } }
        })
    }
}
