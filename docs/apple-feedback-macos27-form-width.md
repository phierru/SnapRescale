# Apple Feedback draft: SwiftUI scroll container lays out 430 pt wide after an in-event state change

Area: SwiftUI · macOS 27.0 (26A428) · Xcode 27.0 (27A266a)
Also reproduced with a binary linked against the macOS 26.5 SDK, so it is a runtime change, not a linked-on-or-after one.

## Summary

On macOS 27, a SwiftUI `Form` with `.formStyle(.grouped)` (also `.formStyle(.columns)` and a plain `ScrollView`) placed inside a fixed `.frame(width: 340)` is laid out **430 pt wide** for one layout pass when a `@State`/`@Observable` value it depends on is changed *inside the mouse event* of one of its own controls (Button action, Picker or Slider binding). Its content is laid out for 430 pt as well and overflows the 340 pt frame. The width is a constant 430 regardless of the frame width, of the content's ideal width, or of the row widths. It corrects itself on the next update of the view; if nothing else changes, it stays at 430 indefinitely.

The same value change made outside the event, for example from a `Task`, from `DispatchQueue.main.async` inside the action, or from a timer, is laid out at 340 every time. Hover, `withAnimation`, `Transaction.disablesAnimations`, `.safeAreaInset`, `.scrollDisabled(true)` and the sidebar width make no difference. `List` and a non-scrolling `VStack` are not affected. macOS 26 did not show this.

## Steps to reproduce

1. Build and run the sample below on macOS 27.
2. Click the "+" button in the right-hand panel.
3. Watch the console.

## Expected

The Form reports 340 on every pass. The console shows nothing after the initial `width=340.0`.

## Actual

Console shows `width=430.0` immediately after the click. It stays there until the state changes again outside a mouse event (click "Tick later", which changes the counter from a `Task`, and the Form goes back to 340).

## Sample

```swift
import SwiftUI

@main
struct RepoApp: App {
    var body: some Scene {
        Window("Repro", id: "main") { ContentView() }
            .defaultSize(width: 1000, height: 700)
    }
}

struct ContentView: View {
    @State private var value = 0

    var body: some View {
        HStack(spacing: 0) {
            Color.gray.opacity(0.2).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Form {
                Section("Value") {
                    HStack {
                        Text("\(value)")
                        Spacer()
                        // Changing state inside the click: Form lays out 430 pt wide.
                        Button("+") { value += 1 }
                        // Same change a run-loop turn later: Form stays 340 pt.
                        Button("Tick later") { Task { @MainActor in value += 1 } }
                    }
                    Picker("Kind", selection: $value) {
                        Text("A").tag(0); Text("B").tag(1); Text("C").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                print("width=\(w)")
            }
            .frame(width: 340)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
```

## Notes from the investigation

- Reproduced in SnapRescale (com.phierru.SnapRescale) and in the reduced sample above.
- With `.fixedSize(horizontal: true, vertical: false)` the Form's genuine ideal width is 490, so 430 is not the ideal size either.
- Pinning every row to `.frame(width: 280)` still gives 430; the value is not derived from content.
- Workaround used in the app: every control writes its value via `DispatchQueue.main.async`, so the state change lands outside the event.
