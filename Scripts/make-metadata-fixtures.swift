// make-metadata-fixtures.swift [output-dir]
//
// Regenerates the metadata fixture corpus (issue #10) used by RescaleKit's
// round-trip tests. Everything is synthetic: a drawn test card, placeholder
// names, and GPS at 0°N 0°E ("Null Island"). No camera, no ComfyUI, no
// personal data. Run from the repo root:
//
//     swift Scripts/make-metadata-fixtures.swift
//
// ImageIO writes the pixels and the standard blocks; the chunks and segments it
// will not write (custom PNG text, a hand-made XMP packet) are spliced in here.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "RescaleKit/Tests/RescaleKitTests/Fixtures/metadata")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let W = 64, H = 48

// MARK: - Pixels

/// A test card with four distinct quadrants, so a rotation is visible in the
/// pixels: red top-left, green top-right, blue bottom-left, yellow bottom-right.
func drawCard(_ ctx: CGContext, colour: (CGFloat, CGFloat, CGFloat) -> CGColor) {
    let w = CGFloat(ctx.width), h = CGFloat(ctx.height)
    let quads: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2), colour(1, 0, 0)),      // top-left (CG origin is bottom-left)
        (CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2), colour(0, 1, 0)),  // top-right
        (CGRect(x: 0, y: 0, width: w / 2, height: h / 2), colour(0, 0, 1)),          // bottom-left
        (CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2), colour(1, 1, 0)),      // bottom-right
    ]
    for (r, c) in quads { ctx.setFillColor(c); ctx.fill(r) }
    ctx.setFillColor(colour(0.5, 0.5, 0.5))
    ctx.fillEllipse(in: CGRect(x: w / 2 - 8, y: h / 2 - 8, width: 16, height: 16))
}

func rgbCard(space name: CFString = CGColorSpace.sRGB, bits: Int = 8, width: Int = W, height: Int = H) -> CGImage {
    let space = CGColorSpace(name: name)!
    var info = CGImageAlphaInfo.noneSkipLast.rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                        space: space, bitmapInfo: info)!
    drawCard(ctx) { r, g, b in CGColor(colorSpace: space, components: [r, g, b, 1])! }
    return ctx.makeImage()!
}

func cmykCard() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.genericCMYK)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    // Naive RGB → CMYK, enough for a test card.
    drawCard(ctx) { r, g, b in
        let k = 1 - max(r, g, b)
        let d = max(1 - k, 0.0001)
        return CGColor(colorSpace: space, components: [(1 - r - k) / d, (1 - g - k) / d, (1 - b - k) / d, k, 1])!
    }
    return ctx.makeImage()!
}

func encode(_ image: CGImage, _ type: UTType, _ properties: [CFString: Any] = [:]) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not encode \(type)") }
    return data as Data
}

// MARK: - PNG chunks

func crc(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
}

func deflate(_ text: String) -> [UInt8] {
    let input = Array(text.utf8)
    var length = compressBound(uLong(input.count))
    var out = [UInt8](repeating: 0, count: Int(length))
    guard compress2(&out, &length, input, uLong(input.count), 9) == Z_OK else { fatalError("deflate") }
    return Array(out.prefix(Int(length)))
}

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let typed = Array(type.utf8) + body
    return be32(UInt32(body.count)) + typed + be32(crc(typed))
}

func tEXt(_ keyword: String, _ text: String) -> [UInt8] {
    chunk("tEXt", Array(keyword.utf8) + [0] + Array(text.utf8))
}

func zTXt(_ keyword: String, _ text: String) -> [UInt8] {
    chunk("zTXt", Array(keyword.utf8) + [0, 0] + deflate(text))      // keyword\0 method(0) zlib
}

func iTXtCompressed(_ keyword: String, _ text: String) -> [UInt8] {
    // keyword\0 compressed(1) method(0) language\0 translated\0 zlib
    chunk("iTXt", Array(keyword.utf8) + [0, 1, 0, 0, 0] + deflate(text))
}

/// Splice chunks in right after IHDR, where PIL (ComfyUI, A1111) puts them.
func png(_ image: CGImage, chunks: [[UInt8]]) -> Data {
    let base = encode(image, .png)
    let head = 8 + 25                                                // signature + IHDR
    var out = Data(base.prefix(head))
    for c in chunks { out.append(contentsOf: c) }
    out.append(base.suffix(from: head))
    return out
}

// MARK: - JPEG segments

let xmpHeader = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]

/// Put our XMP packet after the leading APP0 / Exif APP1 segments, replacing
/// the packet ImageIO derives from the IPTC dictionary (a file has one packet).
func jpeg(_ data: Data, withXMP packet: String) -> Data {
    let payload = xmpHeader + Array(packet.utf8)
    precondition(payload.count + 2 <= 0xFFFF)
    var out = Data(data.prefix(2))
    var i = 2, inserted = false
    func insert() {
        let length = payload.count + 2
        out.append(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
        inserted = true
    }
    while i + 4 <= data.count, data[i] == 0xFF, (0xE0...0xEF).contains(data[i + 1]) {
        let end = i + 2 + (Int(data[i + 2]) << 8 | Int(data[i + 3]))
        let isXMP = data[i + 1] == 0xE1 && data[(i + 4)..<end].starts(with: xmpHeader)
        let leading = data[i + 1] == 0xE0 || (data[i + 1] == 0xE1 && !isXMP)
        if !leading && !inserted { insert() }
        if !isXMP { out.append(data[i..<end]) }
        i = end
    }
    if !inserted { insert() }
    out.append(data.suffix(from: i))
    return out
}

// MARK: - Payloads (all placeholder text)

let comfyPrompt = #"{"3":{"class_type":"KSampler","inputs":{"seed":42,"steps":20,"cfg":7.0,"sampler_name":"euler","scheduler":"normal","denoise":1.0,"model":["4",0],"positive":["6",0],"negative":["7",0],"latent_image":["5",0]}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"placeholder-model.safetensors"}},"5":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":48,"batch_size":1}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a lighthouse on a cliff, synthetic test fixture","clip":["4",1]}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"blurry, watermark","clip":["4",1]}},"8":{"class_type":"VAEDecode","inputs":{"samples":["3",0],"vae":["4",2]}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"fixture","images":["8",0]}}}"#

let comfyWorkflow = #"{"last_node_id":9,"last_link_id":9,"nodes":[{"id":4,"type":"CheckpointLoaderSimple","pos":[20,180],"size":[315,98],"order":0,"mode":0,"outputs":[{"name":"MODEL","type":"MODEL","links":[1]},{"name":"CLIP","type":"CLIP","links":[3,5]},{"name":"VAE","type":"VAE","links":[8]}],"widgets_values":["placeholder-model.safetensors"]},{"id":5,"type":"EmptyLatentImage","pos":[470,610],"size":[315,106],"order":1,"mode":0,"outputs":[{"name":"LATENT","type":"LATENT","links":[2]}],"widgets_values":[64,48,1]},{"id":6,"type":"CLIPTextEncode","pos":[415,186],"size":[422,164],"order":2,"mode":0,"inputs":[{"name":"clip","type":"CLIP","link":3}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[4]}],"widgets_values":["a lighthouse on a cliff, synthetic test fixture"]},{"id":7,"type":"CLIPTextEncode","pos":[413,389],"size":[425,180],"order":3,"mode":0,"inputs":[{"name":"clip","type":"CLIP","link":5}],"outputs":[{"name":"CONDITIONING","type":"CONDITIONING","links":[6]}],"widgets_values":["blurry, watermark"]},{"id":3,"type":"KSampler","pos":[863,186],"size":[315,262],"order":4,"mode":0,"inputs":[{"name":"model","type":"MODEL","link":1},{"name":"positive","type":"CONDITIONING","link":4},{"name":"negative","type":"CONDITIONING","link":6},{"name":"latent_image","type":"LATENT","link":2}],"outputs":[{"name":"LATENT","type":"LATENT","links":[7]}],"widgets_values":[42,"fixed",20,7.0,"euler","normal",1.0]},{"id":8,"type":"VAEDecode","pos":[1209,188],"size":[210,46],"order":5,"mode":0,"inputs":[{"name":"samples","type":"LATENT","link":7},{"name":"vae","type":"VAE","link":8}],"outputs":[{"name":"IMAGE","type":"IMAGE","links":[9]}]},{"id":9,"type":"SaveImage","pos":[1451,189],"size":[210,270],"order":6,"mode":0,"inputs":[{"name":"images","type":"IMAGE","link":9}],"widgets_values":["fixture"]}],"links":[[1,4,0,3,0,"MODEL"],[2,5,0,3,3,"LATENT"],[3,4,1,6,0,"CLIP"],[4,6,0,3,1,"CONDITIONING"],[5,4,1,7,0,"CLIP"],[6,7,0,3,2,"CONDITIONING"],[7,3,0,8,0,"LATENT"],[8,4,2,8,1,"VAE"],[9,8,0,9,0,"IMAGE"]],"groups":[],"config":{},"extra":{},"version":0.4}"#

let a1111Parameters = """
a lighthouse on a cliff, synthetic test fixture
Negative prompt: blurry, watermark
Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 42, Size: 64x48, Model hash: 0000000000, Model: placeholder-model, Version: v1.0.0-fixture
"""

let xmpPacket = """
<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmp:Rating="4"
    xmp:Label="Placeholder label"
    xmp:CreatorTool="SnapRescale fixture generator"
    photoshop:City="Null Island"
    photoshop:Credit="Placeholder Agency"
    exif:GPSLatitude="0,0.0000N"
    exif:GPSLongitude="0,0.0000E">
   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Synthetic test caption</rdf:li></rdf:Alt></dc:description>
   <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">Placeholder copyright</rdf:li></rdf:Alt></dc:rights>
   <dc:creator><rdf:Seq><rdf:li>Placeholder Author</rdf:li></rdf:Seq></dc:creator>
   <dc:subject><rdf:Bag><rdf:li>fixture</rdf:li><rdf:li>synthetic</rdf:li></rdf:Bag></dc:subject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""

// MARK: - The corpus

var files: [(String, Data)] = []

// 1. Camera-style JPEG: EXIF + TIFF tags, GPS at Null Island, embedded thumbnail.
files.append(("camera-exif-gps-thumbnail.jpg", encode(rgbCard(), .jpeg, [
    kCGImageDestinationLossyCompressionQuality: 0.8,
    kCGImageDestinationEmbedThumbnail: true,
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Synthetic Camera Co",
        kCGImagePropertyTIFFModel: "Fixture One",
        kCGImagePropertyTIFFSoftware: "make-metadata-fixtures",
        kCGImagePropertyTIFFDateTime: "2020:01:01 12:00:00",
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifLensMake: "Synthetic Optics",
        kCGImagePropertyExifLensModel: "Fixture 50mm f/1.8",
        kCGImagePropertyExifExposureTime: 1.0 / 125,
        kCGImagePropertyExifFNumber: 5.6,
        kCGImagePropertyExifISOSpeedRatings: [100],
        kCGImagePropertyExifFocalLength: 50.0,
        kCGImagePropertyExifDateTimeOriginal: "2020:01:01 12:00:00",
        kCGImagePropertyExifDateTimeDigitized: "2020:01:01 12:00:00",
    ],
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E",
        kCGImagePropertyGPSAltitude: 0.0, kCGImagePropertyGPSAltitudeRef: 0,
        kCGImagePropertyGPSDateStamp: "2020:01:01", kCGImagePropertyGPSTimeStamp: "12:00:00",
    ],
])))

// 2. IPTC (IIM, written by ImageIO) + a hand-made XMP packet that mirrors the
//    caption, rights, city and a GPS position.
let iptcBase = encode(rgbCard(), .jpeg, [
    kCGImageDestinationLossyCompressionQuality: 0.8,
    kCGImagePropertyIPTCDictionary: [
        kCGImagePropertyIPTCCaptionAbstract: "Synthetic test caption",
        kCGImagePropertyIPTCKeywords: ["fixture", "synthetic"],
        kCGImagePropertyIPTCCredit: "Placeholder Agency",
        kCGImagePropertyIPTCCopyrightNotice: "Placeholder copyright",
        kCGImagePropertyIPTCByline: ["Placeholder Author"],
        kCGImagePropertyIPTCCity: "Null Island",
    ],
])
files.append(("iptc-xmp.jpg", jpeg(iptcBase, withXMP: xmpPacket)))

// 3. Stored landscape, flagged "rotate 90° clockwise to display".
files.append(("rotated-orientation-6.jpg", encode(rgbCard(), .jpeg, [
    kCGImageDestinationLossyCompressionQuality: 0.8,
    kCGImagePropertyOrientation: 6,
])))

// 4. Display P3 HEIC.
files.append(("display-p3.heic", encode(rgbCard(space: CGColorSpace.displayP3), .heic, [
    kCGImageDestinationLossyCompressionQuality: 0.8,
])))

// 5. 16 bits per channel, LZW.
files.append(("16-bit.tiff", encode(rgbCard(bits: 16), .tiff, [
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
])))

// 6. CMYK JPEG.
files.append(("cmyk.jpg", encode(cmykCard(), .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.8])))

// 7. ComfyUI: API graph in `prompt`, UI graph in `workflow`.
files.append(("comfyui.png", png(rgbCard(), chunks: [tEXt("prompt", comfyPrompt), tEXt("workflow", comfyWorkflow)])))

// 8. A1111 PNG.
files.append(("a1111.png", png(rgbCard(), chunks: [tEXt("parameters", a1111Parameters)])))

// 9. A1111 JPEG: the same parameters in EXIF UserComment.
files.append(("a1111-usercomment.jpg", encode(rgbCard(), .jpeg, [
    kCGImageDestinationLossyCompressionQuality: 0.8,
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: a1111Parameters],
])))

// 10. The ComfyUI graphs again, deflated: `prompt` as zTXt, `workflow` as compressed iTXt.
files.append(("compressed-text.png", png(rgbCard(), chunks: [zTXt("prompt", comfyPrompt),
                                                             iTXtCompressed("workflow", comfyWorkflow)])))

for (name, data) in files {
    try data.write(to: outDir.appendingPathComponent(name))
    print(String(format: "%6d  %@", data.count, name))
}
