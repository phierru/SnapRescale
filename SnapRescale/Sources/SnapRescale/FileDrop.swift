import AppKit
import SwiftUI

/// Accepts file drops onto the window through AppKit rather than
/// `.dropDestination`, to learn when the drag session is really over.
/// On macOS 27 a state change made before the session ends lays the sidebar
/// Form out 430 pt wide (GitHub #2), and the session outlives the drop by the
/// source's drop animation (about 300 ms from Finder). SwiftUI reports only
/// the drop; `draggingEnded` arrives after that animation.
struct FileDropTarget: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView { DropView(onDrop: onDrop) }
    func updateNSView(_ view: DropView, context: Context) { view.onDrop = onDrop }

    final class DropView: NSView {
        var onDrop: ([URL]) -> Void
        private var dropped: [URL]?

        init(onDrop: @escaping ([URL]) -> Void) {
            self.onDrop = onDrop
            super.init(frame: .zero)
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) { fatalError() }

        // Transparent to clicks: the crop drag and the controls stay live.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func urls(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
            urls(info).isEmpty ? [] : .copy
        }
        override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
            urls(info).isEmpty ? [] : .copy
        }
        override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
            dropped = urls(info)
            return !(dropped ?? []).isEmpty
        }
        override func draggingEnded(_ info: NSDraggingInfo) {
            guard let urls = dropped else { return }
            dropped = nil
            deferred { self.onDrop(urls) }
        }
    }
}
