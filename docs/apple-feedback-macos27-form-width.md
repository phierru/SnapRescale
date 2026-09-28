# Apple Feedback draft: SwiftUI scroll container lays out 430 pt wide after a state change during event handling

Area: SwiftUI · macOS 27.0 (26A428) · Xcode 27.0 (27A266a)
Also reproduced with a binary linked against the macOS 26.5 SDK, so it is a runtime change, not a linked-on-or-after one.

## Summary

On macOS 27, a SwiftUI `Form` with `.formStyle(.grouped)` (also `.formStyle(.columns)` and a plain `ScrollView`) placed inside a fixed `.frame(width: 340)` is laid out **430 pt wide** when a `@State`/`@Observable` value it depends on changes while AppKit is still handling an event. Its content is laid out for 430 pt as well and overflows the 340 pt frame. The width is a constant 430 regardless of the frame width, of the content's ideal width, or of the row widths. It corrects itself on the next update of the view; if nothing else changes, it stays at 430 indefinitely.

Triggers we measured, each changing the same model the Form displays:

1. **A click on one of the Form's own controls** (Button action, Picker or Slider binding), and a `DragGesture` on a view next to the Form.
2. **A drop through `.dropDestination`**, on a view outside the Form. A change made in the drop action, or up to at least 150 ms later, goes wide. A change 300 ms or more after the drop does not. The drag source's `draggingSession(_:endedAt:operation:)` fires about 300 ms after the drop action, so the window seems to be "until the drag session ends": SwiftUI's drop animation keeps the session alive after the drop.
3. **A file opened through `NSApplicationDelegate.application(_:open:)`** (Finder "Open With", Dock drop, `open -a`), with the change made directly in the delegate method.
4. **The return from `NSOpenPanel.runModal()`**, with the change made right after it returns.

The same change made outside the event is laid out at 340 every time, for example from a `Task` or a timer. That includes an Apple-event open while the app stays in the background (`open -g`). Hover, app activation, `withAnimation`, `Transaction.disablesAnimations`, `.safeAreaInset`, `.scrollDisabled(true)` and the sidebar width make no difference. `List` and a non-scrolling `VStack` are not affected. macOS 26 did not show this.

## Steps to reproduce

SnapRescale is open source (MIT). The commit before our workaround shows the bug in its unmodified form:

1. `git clone https://github.com/phierru/SnapRescale && cd SnapRescale && git checkout 110e688`
2. `Scripts/build-app.sh release` (SwiftPM, no Xcode project needed), then open `build/SnapRescale.app`.
3. Open any image (drag it onto the window, or File ▸ Open).
4. Click any control in the right-hand panel, for example "+" next to the width, or "Height".
5. Drop a second image onto the window.

## Expected

The right-hand panel stays 340 pt wide.

## Actual

After step 3, 4 or 5 the panel's Form is laid out 430 pt wide: its rows are cut off at the right edge and the preview on the left shrinks. It returns to 340 on the next change made outside an event.

## Notes from the investigation

- A reduced sample (a `Form` in `.frame(width: 340)` next to a `Color`, a Button changing a `@State` Int, a segmented Picker and a `.dropDestination`) did **not** reproduce the bug, as a bare executable or as an app bundle, even with a row whose single-line width is over 340 pt. Something in SnapRescale's view tree is needed as well; we have not isolated it.
- With `.fixedSize(horizontal: true, vertical: false)` the Form's genuine ideal width in SnapRescale is 490, so 430 is not the ideal size either.
- Pinning every row to `.frame(width: 280)` still gives 430; the value is not derived from content.
- A drag that only hovers over the window and is cancelled does not trigger it.

## Workaround we ship (SnapRescale 1.1, `Deferred.swift`, `FileDrop.swift`)

- Clicks, gestures and sliders write their state on the next main-queue turn (`DispatchQueue.main.async`). That is enough for these, and it still updates live during a drag.
- The open panel, `application(_:open:)`, menu commands and Settings write through `RunLoop.main.perform(inModes: [.default])` followed by a `Task { @MainActor in … }` hop. The main-queue hop alone was not enough right after the open panel closes.
- Drops no longer use `.dropDestination`. An AppKit `NSView` overlay (registered for file URLs, `hitTest` returning `nil`) takes the drop and loads the file in `draggingEnded(_:)`. Without SwiftUI's drop animation the session ends at once, and the change is laid out at 340.
