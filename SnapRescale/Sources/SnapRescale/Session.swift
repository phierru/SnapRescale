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
    /// It shows the colours Save will write (PRD §7, §10.2): the source's own
    /// when the ICC policy keeps its colour space, the sRGB conversion otherwise.
    var previewImage: CGImage? {
        guard let source, let spec else { return sourcePreview }
        return ColorPlan(source: source, spec: spec).keepsSourceSpace ? sourcePreview : sRGBPreview
    }
    /// The preview in the source's colour space, and converted to sRGB (the
    /// same image when the source is sRGB already).
    private var sourcePreview: CGImage?
    private var sRGBPreview: CGImage?

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
    var format: OutputFormat = .keepOriginal {
        didSet { if let s = source, format.isAvailable(for: s.type) { formatNote = nil } }
    }
    var quality: Double = AppSettings.shared.defaultQuality

    // Metadata (PRD §10.2). A new image resets it to the default, so that nothing
    // kept for one picture is kept for the next by accident; a preset sets it.
    var metadataPolicy: MetadataPolicy = .default

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
        quality = Double(Preset.percent(preset.quality)) / 100
        metadataPolicy = preset.metadata
        resolveFormat()   // a preset may ask for "keep" on a source that cannot be kept (review C5)
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
               padColor: padColor, format: format, quality: quality, metadata: metadataPolicy)
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

    /// Black grid and frame instead of white, for light pictures (GitHub #7). Remembered.
    var gridDark: Bool = UserDefaults.standard.bool(forKey: "compositionGridDark") {
        didSet { UserDefaults.standard.set(gridDark, forKey: "compositionGridDark") }
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
                          padColor: padColor, format: format, quality: quality, metadata: metadataPolicy)
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
                    // Exactly two numbers: "16:x:9" is not 16:9 (review 2026-09-30, S4).
                    let p = v.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
                    if p.count == 2, let w = p[0], let h = p[1], w > 0, h > 0 { aspect = .fixed(width: w, height: h) }
                }
                launchAspect = aspect
            case "--width", "--height", "--mp", "--scale":
                guard let v = it.next(), let d = Double(v) else { break }
                sizeKind = a == "--width" ? .width : a == "--height" ? .height : a == "--mp" ? .megapixels : .scale
                sizeValue = d
                launchSizeValue = d
            case "--multiple":
                if let v = it.next(), let n = Int(v), let m = Multiple(rawValue: n) { multiple = m; launchMultiple = m }
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
                    let p = v.lowercased().split(separator: "x", omittingEmptySubsequences: false).map { Double($0) }
                    if p.count == 2, let w = p[0], let h = p[1], w.isFinite, h.isFinite, w > 0, h > 0 {
                        launchWindowSize = CGSize(width: w, height: h)
                    }
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
    private var launchMultiple: Multiple?
    private var launchAspect: AspectRatio?
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
    /// Each load gets a number; only the latest may commit (review 2026-09-06, C1).
    private var loadGeneration = 0

    /// Saving needs a settled source: not while a replacement is decoding.
    var canSave: Bool { source != nil && !isLoading && !isSaving }

    /// Decodes off the main actor so a large file does not freeze the window.
    /// At most one decode runs; a load requested meanwhile waits as the single
    /// pending one, and a newer request takes its place. A decode cannot be
    /// interrupted, so starting one per request would let a burst of drops
    /// hold that many full-size images at once (review 2026-09-30).
    func load(_ url: URL) {
        loadGeneration += 1
        pendingLoad = url
        isLoading = true
        guard !decodeRunning else { return }
        decodeRunning = true
        Task {
            while let url = pendingLoad {
                pendingLoad = nil
                await decode(url, generation: loadGeneration)
            }
            decodeRunning = false
        }
    }
    private var pendingLoad: URL?
    private var decodeRunning = false

    private func decode(_ url: URL, generation: Int) async {
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let (loaded, preview, converted) = try await Task.detached(priority: .userInitiated) {
                let loaded = try SourceImage.load(url)
                let preview = Self.makePreview(loaded.image, maxPixels: 2048)
                return (loaded, preview, Self.convertedToSRGB(preview))
            }.value
            // A newer load was requested while this one decoded: drop it.
            guard generation == loadGeneration else { return }
            source = loaded
            sourcePreview = preview
            sRGBPreview = converted
            anchor = .center
            // Defaults for a new image (review C7); launch overrides win.
            aspect = launchAspect ?? .original
            launchAspect = nil
            multiple = launchMultiple ?? AppSettings.shared.defaultMultiple
            launchMultiple = nil
            quality = AppSettings.shared.defaultQuality
            metadataPolicy = .default
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
            resolveFormat()
            scheduleEncode()
            if saveOnLoad { saveOnLoad = false; isLoading = false; saveNextToOriginal() }
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription }
        }
    }

    /// Set when the source format could not be kept.
    private(set) var formatNote: String?

    /// "Keep original" cannot keep GIF, WebP, RAW…: switch to an honest format
    /// rather than silently writing JPEG. Used by load and by preset application.
    private func resolveFormat() {
        guard let source else { return }
        if format.isAvailable(for: source.type) {
            formatNote = nil
        } else {
            format = OutputFormat.fallback(for: source.type, hasAlpha: source.hasAlpha)
            formatNote = "\(source.type.preferredFilenameExtension?.uppercased() ?? "This format") cannot be written; saving as \(format.label)."
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // The modal panel runs inside the click that opened it (GitHub #2).
        if panel.runModal() == .OK, let url = panel.url { deferred { self.load(url) } }
    }

    /// Downsampled in the source's own colour space, so a wide-gamut source is
    /// not squeezed into sRGB before the ICC policy has a say (PRD §10.2).
    nonisolated private static func makePreview(_ image: CGImage, maxPixels: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixels else { return image }
        let scale = Double(maxPixels) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        // Only RGB spaces take this pixel format; anything else previews in sRGB.
        let own = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
        return draw(image, width: w, height: h, space: own) ?? draw(image, width: w, height: h, space: nil) ?? image
    }

    /// What `convertToSRGB` and `strip` write: the same picture in sRGB.
    nonisolated private static func convertedToSRGB(_ image: CGImage) -> CGImage {
        if image.colorSpace?.name == CGColorSpace.sRGB { return image }
        return draw(image, width: image.width, height: image.height, space: nil) ?? image
    }

    /// `space` nil means sRGB.
    nonisolated private static func draw(_ image: CGImage, width: Int, height: Int, space: CGColorSpace?) -> CGImage? {
        guard let space = space ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
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
    /// A render job is the source *and* the spec, so a byte count can never be
    /// published for a different image than the one it was rendered from
    /// (review 2026-09-06, C2).
    private struct EncodeJob { let source: SourceImage; let spec: RenderSpec }
    private var pendingJob: EncodeJob?
    private var encodeRunning = false

    func scheduleEncode() {
        guard let source, let spec else { outputBytes = nil; pendingJob = nil; return }
        pendingJob = EncodeJob(source: source, spec: spec)
        isEncoding = true
        guard !encodeRunning else { return }
        encodeRunning = true
        Task { [weak self] in
            // Coalesce a burst of edits before starting a full-size render.
            try? await Task.sleep(for: .milliseconds(80))
            while let self, let job = self.pendingJob {
                self.pendingJob = nil
                let bytes = await Task.detached(priority: .userInitiated) {
                    (try? Renderer.produce(job.source, spec: job.spec))?.count
                }.value
                // Publish only if nothing newer is queued and the session still
                // shows this source with these settings.
                if self.pendingJob == nil, self.source?.url == job.source.url, self.spec == job.spec {
                    self.outputBytes = bytes
                }
            }
            self?.encodeRunning = false
            self?.isEncoding = false
        }
    }

    /// ⌘S. The panel is the default (sandbox-honest, and the name can be tweaked);
    /// the silent path is a preference, and what `--save` uses for scripting.
    private(set) var isSaving = false

    func save() {
        guard canSave else { return }
        if saveWithoutAsking { saveNextToOriginal() } else { saveAs() }
    }

    func saveNextToOriginal() {
        guard canSave, let source, let spec else { return }
        write(to: OutputNaming.url(for: source, spec: spec), source: source, spec: spec, viaFolderAccess: true)
    }

    func saveAs() {
        guard canSave, let source, let spec else { return }
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
    /// the sandbox. The save panel path already carries its own grant. The
    /// encode runs off the main actor; the window shows a saving state meanwhile.
    /// Both paths replace an existing file as a whole, or not at all (`SafeWrite`).
    private func write(to url: URL, source: SourceImage, spec: RenderSpec, viaFolderAccess: Bool = false) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Renderer.produce(source, spec: spec)
                }.value
                if viaFolderAccess {
                    switch FolderAccess.write(data, to: url) {
                    case .written: break
                    case .cancelled: return
                    case .failed(let error): throw error
                    }
                } else {
                    try SafeWrite.write(data, to: url)
                }
                // Only a committed file is reported as saved (review 2026-09-30, G1).
                lastSaved = url
                if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if quitsAfterSave {
                    // Let the Finder reveal go out first, then finish the one-shot session.
                    try? await Task.sleep(for: .milliseconds(300))
                    NSApp.terminate(nil)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { min(max(self, r.lowerBound), r.upperBound) }
}
