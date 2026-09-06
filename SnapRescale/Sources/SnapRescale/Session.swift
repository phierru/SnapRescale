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
    var multiple: Multiple = AppSettings.shared.defaultMultiple

    // Fit (PRD §7)
    var fit: FitPolicy = .crop
    var anchor: CropAnchor = .center
    var padColor: PadColor? = .white

    // Encoder (PRD §9)
    var format: OutputFormat = .keepOriginal
    var quality: Double = AppSettings.shared.defaultQuality

    // Presets (PRD §12)
    let presets = PresetStore()
    /// Name of the preset the current settings came from; nil once anything changed.
    private(set) var activePreset: String?

    func apply(_ preset: Preset) {
        aspect = preset.aspect
        multiple = preset.multiple
        fit = preset.fit
        padColor = preset.padColor
        format = preset.format
        quality = preset.quality
        switch preset.size {
        case .width(let w): sizeKind = .width; sizeValue = Double(w)
        case .height(let h): sizeKind = .height; sizeValue = Double(h)
        case .megapixels(let mp): sizeKind = .megapixels; sizeValue = mp
        case .scale(let k): sizeKind = .scale; sizeValue = k * 100
        }
        activePreset = preset.name
    }

    /// The current settings as a preset.
    func currentPreset(named name: String) -> Preset {
        Preset(name: name, aspect: aspect, size: sizeParameter, multiple: multiple, fit: fit,
               padColor: padColor, format: format, quality: quality)
    }

    /// Called from the view when any setting changes: the settings no longer match a preset by name.
    func noteSettingsChanged() {
        guard let name = activePreset, let p = presets.presets.first(where: { $0.name == name }) else {
            activePreset = nil; return
        }
        if currentPreset(named: name) != p { activePreset = nil }
    }

    // Display only
    var grid: CompositionGrid = CompositionGrid.loadPreference() {
        didSet { grid.savePreference() }
    }

    // Saving preferences live in AppSettings; proxies keep call sites short.
    var revealAfterSave: Bool { AppSettings.shared.revealAfterSave }
    var saveWithoutAsking: Bool { AppSettings.shared.saveWithoutAsking }

    // Output
    private(set) var outputBytes: Int?
    private(set) var isEncoding = false
    private(set) var lastSaved: URL?
    var errorMessage: String?

    enum SizeKind: String, CaseIterable, Identifiable {
        case width = "Width", height = "Height", megapixels = "Megapixels", scale = "Scale"
        var id: String { rawValue }
    }

    /// The quick-pick row under the field. Pixel values are the common AI input
    /// sizes (all divisible by 8 and 16, PRD §5); the other views get their own ladders.
    /// Values past the source are not dimmed (a segmented control cannot); the
    /// upscale note under Output covers it.
    var ladder: [Double] {
        switch sizeKind {
        case .width, .height: return AppSettings.shared.ladder.map(Double.init)
        case .megapixels: return [0.25, 0.5, 1, 2, 4]
        case .scale: return [25, 50, 75, 100]
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

    /// Whatever the field holds, clamped to a legal value (finding 3): a
    /// non-finite or non-positive entry never reaches the solver.
    var sizeParameter: SizeParameter {
        let v = sizeValue.isFinite ? sizeValue : 1
        let px = Int(exactly: v.rounded().clamped(to: 1...Double(Limits.maxDimension))) ?? 1
        switch sizeKind {
        case .width: return .width(px)
        case .height: return .height(px)
        case .megapixels: return .megapixels(v).clamped
        case .scale: return .scale(v / 100).clamped
        }
    }

    /// Non-nil when the field holds something the solver had to clamp.
    var sizeProblem: String? {
        let raw: SizeParameter
        switch sizeKind {
        case .width: raw = .width(sizeValue.isFinite ? Int(clamping: Int64(sizeValue.rounded().clamped(to: -1e15...1e15))) : 0)
        case .height: raw = .height(sizeValue.isFinite ? Int(clamping: Int64(sizeValue.rounded().clamped(to: -1e15...1e15))) : 0)
        case .megapixels: raw = .megapixels(sizeValue)
        case .scale: raw = .scale(sizeValue / 100)
        }
        do { try raw.validate(); return nil } catch { return error.localizedDescription }
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

    /// True when the solved size has a different ratio from the source, so the
    /// renderer will crop or pad. Under Original this can still happen by a few
    /// pixels when the multiple rounds an axis (PRD §5).
    var reframes: Bool {
        guard let source, let solution else { return false }
        return abs(solution.size.aspectRatio - source.size.aspectRatio) > 1e-6
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
                    if p.count == 2, p[0] > 0, p[1] > 0 { aspect = .fixed(width: p[0], height: p[1]) }
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
            case "--save":
                saveOnLoad = true
            case "--preset":
                if let v = it.next() { launchPreset = v }
            case "--settings":
                openSettingsOnLaunch = true
            case "--window":
                // "1440x900": frame size in points, for App Store screenshots (2× → 2880×1800).
                if let v = it.next() {
                    let p = v.lowercased().split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { launchWindowSize = CGSize(width: p[0], height: p[1]) }
                }
            case "--about":
                openWindowOnLaunch = "about"
            case "--help-window":
                openWindowOnLaunch = "help"
            default:
                if !a.hasPrefix("-"), FileManager.default.fileExists(atPath: a) {
                    accept([URL(fileURLWithPath: a)], origin: .external)
                }
            }
        }
    }
    private var launchSizeValue: Double?
    private var launchPreset: String?
    /// `--settings`: the root view opens the Settings window once it appears (screenshots, tests).
    var openSettingsOnLaunch = false
    /// `--about` / `--help-window`: id of a window to open once the root view appears.
    var openWindowOnLaunch: String?
    var launchWindowSize: CGSize?

    // MARK: Session lifetime (PRD §8)

    /// Where an image came from. Decides whether this is a one-shot session.
    enum Origin { case external, user }

    private let launchDate = Date()
    /// True when the app was *launched for* an image (Open With, Services,
    /// Dock drop): it quits after a successful save. False when it was opened
    /// from the Applications menu and the image arrived by drop or ⌘O.
    private(set) var quitsAfterSave = false
    /// `--save` launch argument: save immediately after loading (scripting).
    private var saveOnLoad = false

    func accept(_ urls: [URL], origin: Origin = .user) {
        guard let url = urls.first else { return }
        if urls.count > 1 {
            errorMessage = "SnapRescale takes one image at a time. Drop a single file."
            return
        }
        if origin == .external, source == nil, Date().timeIntervalSince(launchDate) < 3 {
            quitsAfterSave = true
        }
        load(url)
    }

    private(set) var isLoading = false

    /// Decodes off the main actor so a large file does not freeze the window.
    func load(_ url: URL) {
        isLoading = true
        Task {
            do {
                let (loaded, preview) = try await Task.detached(priority: .userInitiated) {
                    let loaded = try SourceImage.load(url)
                    return (loaded, Self.makePreview(loaded.image, maxPixels: 2048))
                }.value
                source = loaded
                previewImage = preview
                anchor = .center
                if let v = launchSizeValue {
                    sizeValue = v
                    launchSizeValue = nil
                } else {
                    sizeKind = .width
                    sizeValue = Double(min(loaded.size.width, 2048))
                }
                if let name = launchPreset, let p = presets.presets.first(where: { $0.name == name }) {
                    apply(p)
                    launchPreset = nil
                }
                lastSaved = nil
                // "Keep original" cannot keep GIF, WebP, RAW…: switch to an honest
                // format rather than silently writing JPEG (finding 5).
                if !format.isAvailable(for: loaded.type) {
                    format = OutputFormat.fallback(for: loaded.type, hasAlpha: loaded.hasAlpha)
                    formatNote = "\(loaded.type.preferredFilenameExtension?.uppercased() ?? "This format") cannot be written; saving as \(format.label)."
                } else {
                    formatNote = nil
                }
                scheduleEncode()
                if saveOnLoad { saveOnLoad = false; saveNextToOriginal() }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Set when the source format could not be kept.
    private(set) var formatNote: String?

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    nonisolated private static func makePreview(_ image: CGImage, maxPixels: Int) -> CGImage {
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

    /// Selecting a view makes it the controlling input, carrying the current
    /// solved value across at full precision; only the field's text is rounded.
    /// The solver then re-solves for that view: pinning width holds one axis,
    /// megapixels frees both, so at multiple 16 the derived axis can legally
    /// move by one step (PRD §5, §6). The notes under Output say when it does.
    func switchSizeKind(to kind: SizeKind) {
        guard kind != sizeKind else { return }
        if let solution, let source {
            switch kind {
            case .width: sizeValue = Double(solution.width)
            case .height: sizeValue = Double(solution.height)
            case .megapixels: sizeValue = solution.megapixels
            case .scale: sizeValue = solution.scale(relativeTo: source.size) * 100
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

    /// Latest-request-wins: at most one render runs; anything requested while
    /// it runs collapses into a single pending spec (finding 8). ImageIO work
    /// cannot be interrupted, so cancelling tasks alone would not bound memory.
    private var pendingSpec: RenderSpec?
    private var encodeRunning = false

    func scheduleEncode() {
        guard let source, let spec else { outputBytes = nil; pendingSpec = nil; return }
        pendingSpec = spec
        isEncoding = true
        guard !encodeRunning else { return }
        encodeRunning = true
        Task { [weak self] in
            // Coalesce a burst of edits before starting a full-size render.
            try? await Task.sleep(for: .milliseconds(80))
            while let self, let spec = self.pendingSpec {
                self.pendingSpec = nil
                let bytes = await Task.detached(priority: .userInitiated) {
                    (try? Renderer.produce(source, spec: spec))?.count
                }.value
                if self.pendingSpec == nil {
                    self.outputBytes = bytes
                }
            }
            self?.encodeRunning = false
            self?.isEncoding = false
        }
    }

    /// ⌘S. The panel is the default (sandbox-honest, and the name can be tweaked);
    /// the silent path is a preference, and what `--save` uses for scripting.
    func save() {
        if saveWithoutAsking { saveNextToOriginal() } else { saveAs() }
    }

    func saveNextToOriginal() {
        guard let source, let spec else { return }
        write(to: OutputNaming.url(for: source, spec: spec), source: source, spec: spec, viaFolderAccess: true)
    }

    func saveAs() {
        guard let source, let spec else { return }
        let suggested = OutputNaming.url(for: source, spec: spec)
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = spec.format.resolvedType(for: source.type).map { [$0] } ?? []
        if panel.runModal() == .OK, let url = panel.url {
            write(to: url, source: source, spec: spec)
        }
    }

    /// `viaFolderAccess` is the silent path: it may ask for the folder once under
    /// the sandbox. The save panel path already carries its own grant.
    private func write(to url: URL, source: SourceImage, spec: RenderSpec, viaFolderAccess: Bool = false) {
        do {
            let data = try Renderer.produce(source, spec: spec)
            if viaFolderAccess {
                switch FolderAccess.write(data, to: url) {
                case .written: break
                case .cancelled: return
                case .failed(let error): throw error
                }
            } else {
                try data.write(to: url)
            }
            lastSaved = url
            if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if quitsAfterSave {
                // Let the Finder reveal go out first, then finish the one-shot session.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    NSApp.terminate(nil)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
