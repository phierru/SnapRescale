import SwiftUI
import AppKit

enum Links {
    static let repository = URL(string: "https://github.com/phierru/SnapRescale")!
    static let issues = URL(string: "https://github.com/phierru/SnapRescale/issues")!
    static let licence = URL(string: "https://github.com/phierru/SnapRescale/blob/main/LICENSE")!
    static let comfyUI = URL(string: "https://github.com/comfyanonymous/ComfyUI")!
    static let metadataDoc = URL(string: "https://github.com/phierru/SnapRescale/blob/main/docs/reference/image-metadata.md")!
    static let privacy = URL(string: "https://github.com/phierru/SnapRescale/blob/main/docs/PRIVACY.md")!
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// About SnapRescale (replaces the standard panel so the credit is on it).
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("SnapRescale").font(.title.weight(.semibold))
                Text("Resize to any ratio, snapped to multiples of 8 and 16.")
                    .foregroundStyle(.secondary)
                Text("Version \(AppInfo.version)").font(.callout).foregroundStyle(.tertiary)
            }
            Divider().padding(.horizontal, 40)
            VStack(spacing: 6) {
                Text("© 2026 Francesco Lardieri · MIT licence")
                    .font(.callout)
                Text("Inspired by ComfyUI's Resize Image/Mask and Resolution Selector nodes. SnapRescale implements its own resizing solver and macOS image pipeline. Thank you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 360)
            }
            HStack(spacing: 14) {
                Link("Source on GitHub", destination: Links.repository)
                Link("Licence", destination: Links.licence)
                Link("Privacy Policy", destination: Links.privacy)
                Link("ComfyUI", destination: Links.comfyUI)
            }
            .font(.callout)
            Text("No network, no analytics, no accounts. Images stay on your Mac.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 440)
    }
}

/// SnapRescale Help (⌘?). Deliberately brief; the PRD is the long version.
struct HelpView: View {
    struct Section: Identifiable {
        let title: String
        let lines: [String]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Getting an image in", lines: [
            "Right-click an image in Finder → **Open With → SnapRescale**, or **Services → Resize with SnapRescale**. The window then quits after saving.",
            "Or open SnapRescale from Applications and **drop an image** on the window, or press **⌘O**. The window stays open.",
            "One image at a time. Dropping another replaces it.",
        ]),
        Section(title: "Choosing a size", lines: [
            "Pick an **aspect ratio** — Original keeps the image's own — and **one number**: width, height, megapixels or scale. The other three follow.",
            "**Multiple of 8 or 16** rounds the result onto a lattice, as diffusion models and video encoders want. The number you typed is kept; the derived side moves, and the panel says by how much.",
            "The **ladder** under the field jumps to the usual sizes. Edit it in Settings.",
        ]),
        Section(title: "Crop or pad", lines: [
            "When the ratio changes, **Crop** keeps the framed region — drag the frame to reframe, double-click to centre — and **Pad** fits the whole image on a canvas of the colour in the well. Opacity 0 means transparent padding, where the format allows it.",
            "The buttons under the image switch the **composition grid**: frame only, centre lines, thirds, golden ratio, fifths.",
        ]),
        Section(title: "Format and saving", lines: [
            "**Keep original** writes the same format as the source when possible; otherwise the app says which format it switched to.",
            "**What the file loses today:** output is 8-bit sRGB, and EXIF, GPS, XMP and AI workflow data are not carried over — a resized ComfyUI PNG no longer reopens its graph. Only the first frame of an animation is used. Metadata controls are on the roadmap.",
            "The **file size** shown is a real encode, not an estimate.",
            "**⌘S** opens the save panel, pre-filled with *name_WxH*. In Settings you can make ⌘S save beside the original without asking; the first save into a folder asks for permission once.",
            "**Presets** bundle every setting. Save your own from the Preset menu; the files are plain JSON.",
        ]),
        Section(title: "The badges", lines: [
            "Next to the file name: what the source carries — colour profile, EXIF, GPS, XMP, HDR, alpha — and where an AI image came from (ComfyUI, A1111, InvokeAI, …). Hover for details. Nothing is written back yet.",
        ]),
        Section(title: "Shortcuts", lines: [
            "**⌘O** open · **⌘S** save · **⇧⌘S** save as · **⌘,** settings · **⌘?** this help",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.sections) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.title).font(.headline)
                        ForEach(s.lines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(LocalizedStringKey(line))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    Link("Full documentation", destination: Links.repository)
                    Link("What the badges detect", destination: Links.metadataDoc)
                    Link("Privacy Policy", destination: Links.privacy)
                    Link("Report an issue", destination: Links.issues)
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 620)
    }
}
