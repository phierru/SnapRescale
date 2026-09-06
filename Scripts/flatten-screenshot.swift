import AppKit
// flatten in.png out.png [w h]: composite onto an opaque dark background, optionally centred on a canvas.
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let W = a.count >= 5 ? Int(a[3])! : cg.width, H = a.count >= 5 ? Int(a[4])! : cg.height
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.draw(cg, in: CGRect(x: (W - cg.width) / 2, y: (H - cg.height) / 2, width: cg.width, height: cg.height))
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out); let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: a[2]))
print("\(W)x\(H)")
