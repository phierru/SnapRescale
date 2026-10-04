import SwiftUI

/// macOS 27 lays a grouped Form (any SwiftUI scroll container) out 430 pt wide
/// for one pass when its state changes *inside* a mouse event on one of its
/// controls, overflowing the 340 pt sidebar until the next update (GitHub #2).
/// The same change made a run-loop turn later is laid out correctly, so
/// discrete writes that start in a mouse event, a drop or a menu command go
/// through here: the sidebar's pickers, size field and buttons, double-click
/// to centre, the inspector, drops, the open panel, file-open Apple events,
/// the File and View menu commands and Settings. Continuous ones, the crop
/// drag and the Quality sliders, use `deferredLive` below. The grid pickers
/// and Settings' reveal toggle and Forget All write directly: the sidebar does
/// not read them. So does the preset naming sheet, whose buttons are not the
/// sidebar's.
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
