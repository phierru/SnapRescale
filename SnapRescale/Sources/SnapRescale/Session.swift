import AppKit
import SwiftUI
import RescaleKit
import UniformTypeIdentifiers

/// The single-image session (PRD §8). One source, one request, one output.
@MainActor @Observable
final class Session {
    static let shared = Session()

    // Source
    private(set) var source: SourceImage?
    /// A ≤2048 px copy for the preview, so a 36 MP source does not go through the GPU on every frame.
    private(set) var previewImage: CGImage?

    // Request (PRD §5): aspect + one number, plus the quantiser.
    var aspect: AspectRatio = .original
    var sizeKind: SizeKind = .width
    var sizeValue: Double = 2048
    var multiple: Multiple = .eight

    // Fit (PRD §7)
    var fit: FitPolicy = .crop
    var anchor: CropAnchor = .center
    var padColor: PadColor? = .white

    // Encoder (PRD §9)
    var format: OutputFormat = .keepOriginal
    var quality: Double = 0.95

    // Output
    private(set) var outputBytes: Int?
    private(set) var isEncoding = false
    private(set) var lastSaved: URL?
    var errorMessage: String?
    private var encodeTask: Task<Void, Never>?

    enum SizeKind: String, CaseIterable, Identifiable {
        case width = "Width", height = "Height", megapixels = "Megapixels", scale = "Scale"
        var id: String { rawValue }
    }

    /// The quick-pick row under the field. Pixel values are the common AI input
    /// sizes (all divisible by 8 and 16, PRD §5); the other views get their own ladders.
    var ladder: [Double] {
        switch sizeKind {
        case .width, .height: return [512, 768, 1024, 1536, 2048]
        case .megapixels: return [0.25, 0.5, 1, 2, 4]
        case .scale: return [25, 50, 75, 100]
        }
    }

    /// A ladder value is out of reach when it would upscale the source (PRD §5: detents past the source dim).
    func ladderExceedsSource(_ v: Double) -> Bool {
        guard let source else { return false }
        switch sizeKind {
        case .width: return v > Double(source.size.width)
        case .height: return v > Double(source.size.height)
        case .megapixels: return v > source.size.megapixels
        case .scale: return v > 100
        }
    }

    func ladderLabel(_ v: Double) -> String {
        switch sizeKind {
        case .width, .height: return String(Int(v))
        case .megapixels: return v < 1 ? String(format: "%.2g", v) : String(format: "%g", v)
        case .scale: return "\(Int(v))%"
        }
    }

    // MARK: Derived

    var sizeParameter: SizeParameter {
        switch sizeKind {
        case .width: return .width(max(1, Int(sizeValue.rounded())))
        case .height: return .height(max(1, Int(sizeValue.rounded())))
        case .megapixels: return .megapixels(max(0.01, sizeValue))
        case .scale: return .scale(max(0.01, sizeValue / 100))
        }
    }

    var request: ResizeRequest {
        ResizeRequest(aspect: aspect, size: sizeParameter, multiple: multiple)
    }

    var solution: Solution? {
        source.map { request.solve(for: $0.size) }
    }

    var spec: RenderSpec? {
        guard let solution else { return nil }
        return RenderSpec(target: solution.size, fit: fit, anchor: anchor,
                          padColor: padColor, format: format, quality: quality)
    }

    var reframes: Bool {
        guard let source else { return false }
        return aspect.reframes(source.size)
    }

    // MARK: Launch arguments

    /// `open -a SnapRescale --args --aspect 16:9 --width 1920 --multiple 16 [file]`
    /// Sets up the request before the document arrives; handy for scripting and screenshots.
    func applyLaunchArguments(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--aspect":
                guard let v = it.next() else { break }
                if v.lowercased() == "original" { aspect = .original }
                else {
                    let p = v.split(separator: ":").compactMap { Int($0) }
                    if p.count == 2 { aspect = .fixed(width: p[0], height: p[1]) }
                }
            case "--width", "--height", "--mp", "--scale":
                guard let v = it.next(), let d = Double(v) else { break }
                sizeKind = a == "--width" ? .width : a == "--height" ? .height : a == "--mp" ? .megapixels : .scale
                sizeValue = d
                launchSizeValue = d
            case "--multiple":
                if let v = it.next(), let n = Int(v), let m = Multiple(rawValue: n) { multiple = m }
            case "--fit":
                if let v = it.next(), let f = FitPolicy(rawValue: v) { fit = f }
            default:
                if !a.hasPrefix("-"), FileManager.default.fileExists(atPath: a) { load(URL(fileURLWithPath: a)) }
            }
        }
    }
    private var launchSizeValue: Double?

    // MARK: Loading

    func accept(_ urls: [URL]) {
        guard let url = urls.first else { return }
        if urls.count > 1 {
            errorMessage = "SnapRescale takes one image at a time. Drop a single file."
            return
        }
        load(url)
    }

    func load(_ url: URL) {
        do {
            let loaded = try SourceImage.load(url)
            source = loaded
            previewImage = Self.makePreview(loaded.image, maxPixels: 2048)
            anchor = .center
            if let v = launchSizeValue {
                sizeValue = v
                launchSizeValue = nil
            } else {
                sizeKind = .width
                sizeValue = Double(min(loaded.size.width, 2048))
            }
            lastSaved = nil
            scheduleEncode()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private static func makePreview(_ image: CGImage, maxPixels: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let scale = Double(maxPixels) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Size editing — four views of one number (PRD §5)

    /// Switching the view carries the *current solved value* into the new view,
    /// so the number on screen never jumps.
    func switchSizeKind(to kind: SizeKind) {
        guard kind != sizeKind else { return }
        if let solution, let source {
            switch kind {
            case .width: sizeValue = Double(solution.width)
            case .height: sizeValue = Double(solution.height)
            case .megapixels: sizeValue = (solution.megapixels * 100).rounded() / 100
            case .scale: sizeValue = (solution.scale(relativeTo: source.size) * 1000).rounded() / 10
            }
        }
        sizeKind = kind
    }

    /// Steppers move by the multiple, not by 1 (PRD §5).
    func step(_ direction: Int, big: Bool = false) {
        let factor = big ? 10.0 : 1.0
        switch sizeKind {
        case .width, .height:
            let m = Double(multiple.rawValue)
            let base = (sizeValue / m).rounded() * m
            sizeValue = max(m, base + Double(direction) * m * factor)
        case .megapixels:
            sizeValue = max(0.01, ((sizeValue + Double(direction) * 0.1 * factor) * 100).rounded() / 100)
        case .scale:
            sizeValue = max(1, sizeValue + Double(direction) * 1 * factor)
        }
    }

    // MARK: Output

    func scheduleEncode() {
        encodeTask?.cancel()
        guard let source, let spec else { outputBytes = nil; return }
        isEncoding = true
        encodeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let bytes = await Task.detached(priority: .userInitiated) {
                (try? Renderer.produce(source, spec: spec))?.count
            }.value
            if Task.isCancelled { return }
            self?.outputBytes = bytes
            self?.isEncoding = false
        }
    }

    func save() {
        guard let source, let spec else { return }
        write(to: OutputNaming.url(for: source, spec: spec), source: source, spec: spec)
    }

    func saveAs() {
        guard let source, let spec else { return }
        let suggested = OutputNaming.url(for: source, spec: spec)
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [spec.format.resolvedType(for: source.type)]
        if panel.runModal() == .OK, let url = panel.url {
            write(to: url, source: source, spec: spec)
        }
    }

    private func write(to url: URL, source: SourceImage, spec: RenderSpec) {
        do {
            let data = try Renderer.produce(source, spec: spec)
            try data.write(to: url)
            lastSaved = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
