// Throwaway CLI (PRD §14 M1): the cheapest way to exercise RescaleKit before
// there is an app. Solves geometry only for now; no pixels are written yet.
//
//   rescale [--aspect 16:9|original] (--width N | --height N | --mp X | --scale X)
//           [--multiple 1|8|16] [--fit crop|pad|stretch] [--format keep|jpeg|png|heic|tiff]
//           [--quality 0.95] [--write] (<image> | --source WxH)

import Foundation
import ImageIO
import RescaleKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rescale: \(message)\n".utf8))
    exit(2)
}

func usage() -> Never {
    print("""
    usage: rescale [--aspect 16:9|original] (--width N | --height N | --mp X | --scale X)
                   [--multiple 1|8|16] [--fit crop|pad|stretch] [--format keep|jpeg|png|heic|tiff]
                   [--quality 0.95] [--write] (<image> | --source WxH)
    """)
    exit(1)
}

func parseAspect(_ s: String) -> AspectRatio {
    if s.lowercased() == "original" { return .original }
    let parts = s.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("bad aspect '\(s)'") }
    return .fixed(width: parts[0], height: parts[1])
}

func parseSize(_ s: String) -> PixelSize {
    let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("bad size '\(s)', want WxH") }
    return PixelSize(parts[0], parts[1])
}

func sourceSize(ofImageAt path: String) -> PixelSize {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { fail("cannot read image dimensions from \(path)") }
    // EXIF orientation 5–8 swap the axes; the solver should see the upright image (PRD §10).
    let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return orientation >= 5 ? PixelSize(h, w) : PixelSize(w, h)
}

var aspect: AspectRatio = .original
var size: SizeParameter?
var multiple: Multiple = .one
var source: PixelSize?
var imagePath: String?
var fit: FitPolicy = .crop
var format: OutputFormat = .keepOriginal
var quality = 0.95
var write = false

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func take() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }

while !args.isEmpty {
    let a = take()
    switch a {
    case "--aspect": aspect = parseAspect(take())
    case "--width": guard let v = Int(take()) else { fail("bad width") }; size = .width(v)
    case "--height": guard let v = Int(take()) else { fail("bad height") }; size = .height(v)
    case "--mp": guard let v = Double(take()) else { fail("bad megapixels") }; size = .megapixels(v)
    case "--scale": guard let v = Double(take()) else { fail("bad scale") }; size = .scale(v)
    case "--multiple":
        guard let v = Int(take()), let m = Multiple(rawValue: v) else { fail("multiple must be 1, 8 or 16") }
        multiple = m
    case "--source": source = parseSize(take())
    case "--fit": guard let f = FitPolicy(rawValue: take()) else { fail("fit must be crop, pad or stretch") }; fit = f
    case "--format":
        switch take().lowercased() {
        case "keep": format = .keepOriginal
        case "jpeg", "jpg": format = .jpeg
        case "png": format = .png
        case "heic": format = .heic
        case "tiff", "tif": format = .tiff
        default: fail("format must be keep, jpeg, png, heic or tiff")
        }
    case "--quality": guard let q = Double(take()), (0...1).contains(q) else { fail("quality must be 0…1") }; quality = q
    case "--write": write = true
    case "-h", "--help": usage()
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)") }
        imagePath = a
    }
}

guard let size else { usage() }
var loaded: SourceImage?
if let imagePath {
    do { loaded = try SourceImage.load(URL(fileURLWithPath: imagePath)) } catch { fail(error.localizedDescription) }
}
if source == nil, let loaded { source = loaded.size }
guard let source else { fail("give an image path or --source WxH") }

let request = ResizeRequest(aspect: aspect, size: size, multiple: multiple)
let s = request.solve(for: source)

print("source   \(source)  (\(String(format: "%.2f", source.megapixels)) MP, \(aspect.label))")
print("ideal    \(String(format: "%.1f×%.1f", s.ideal.width, s.ideal.height))")
print("result   \(s.size)  \(String(format: "%.2f", s.megapixels)) MP  scale \(String(format: "%.1f", s.scale(relativeTo: source) * 100))%")
print("error    aspect \(String(format: "%.3f", s.aspectError * 100))%  pixels \(String(format: "%.2f", s.pixelError * 100))%")
for adj in s.adjustments {
    switch adj {
    case let .pinnedValueSnapped(axis, requested, actual):
        print("note     \(axis) \(requested) is not a multiple of \(multiple.rawValue); using \(actual)")
    case let .derivedAxisForced(axis, ideal, actual):
        print("note     \(aspect.label) wants \(axis) \(ideal); the multiple of \(multiple.rawValue) forces \(actual)")
    }
}
if aspect.reframes(source) {
    let discarded = Geometry.discardedFraction(source: source, target: s.size, anchor: .center)
    print("fit      \(fit.rawValue)\(fit == .crop ? String(format: ", crops %.0f%% of the image", discarded * 100) : "")")
}
if s.isUpscale(from: source, fit: fit) {
    print("warning  larger than the source (upscale)")
}
if write {
    guard let loaded else { fail("--write needs an image path") }
    let spec = RenderSpec(target: s.size, fit: fit, format: format, quality: quality)
    do {
        let data = try Renderer.produce(loaded, spec: spec)
        let url = OutputNaming.url(for: loaded, spec: spec)
        try data.write(to: url)
        print("wrote    \(url.path)  (\(data.count) bytes)")
    } catch { fail(error.localizedDescription) }
}
