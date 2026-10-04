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
                Text("Resize to any ratio, snapped to multiples of 8, 16 or 32.")
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
            "Right-click an image in Finder → **Open With → SnapRescale**, or **Services → Resize with SnapRescale**. If that launches SnapRescale, it quits after saving.",
            "Or open SnapRescale from Applications and **drop an image** on the window, or press **⌘O**. The window stays open.",
            "One image at a time. Dropping another replaces it.",
        ]),
        Section(title: "Choosing a size", lines: [
            "Pick an **aspect ratio** — Original keeps the image's own — and **one number**: width, height, megapixels or scale. The other three follow.",
            "**Multiple of 8, 16 or 32** rounds the result onto a lattice, as diffusion models, image-editing models and video encoders want. A width or height you type is kept when it is already a multiple; otherwise it moves to the nearest one, and the panel says by how much. Sizes are whole pixels, so even at multiple 1 switching between width, height, megapixels and scale can move a side by a pixel.",
            "The **ladder** under the field jumps to the usual sizes. Edit it in Settings.",
        ]),
        Section(title: "Crop or pad", lines: [
            "When the ratio changes, **Crop** keeps the framed region — drag the frame to reframe, double-click to centre — and **Pad** fits the whole image on a canvas of the colour in the well. Opacity 0 means transparent padding, where the format allows it.",
            "The buttons under the image switch the **composition grid**: frame only, centre lines, thirds, golden ratio, fifths.",
        ]),
        Section(title: "Format and saving", lines: [
            "**Keep original** writes the same format as the source when possible; otherwise the app says which format it switched to.",
            "Only the **first frame** of an animation is used, and a CMYK image is converted to sRGB.",
            "The **file size** shown is a real encode, not an estimate.",
            "**⌘S** opens the save panel, pre-filled with *name_WxH*. In Settings you can make ⌘S save beside the original without asking; the first save into a folder asks for permission once.",
            "**Presets** store size and export settings. Save your own from the Preset menu; the files are plain JSON.",
        ]),
        Section(title: "The badges", lines: [
            "Next to the file name: what SnapRescale could read in the source — an embedded colour profile, EXIF, GPS, IPTC, XMP, HDR, alpha — and where an AI image came from (ComfyUI, A1111, InvokeAI, …). Hover for details; click one to open the metadata inspector at that section.",
        ]),
        Section(title: "Metadata", lines: [
            "The **metadata inspector** lists the metadata SnapRescale could read, section by section. PNG text or XMP over the per-image size limit is not read, so it is neither shown nor kept on save; a note says so. Open it with a badge, the **Metadata** row in the sidebar, or **View ▸ Metadata Inspector** (**⌥⌘I**).",
            "Each section has a switch, **Keep · Strip**; the colour profile has **Keep · sRGB · Strip**, where sRGB converts the colours. The menu at the top sets them all — **Default · Keep all · Strip all** — and reads Custom for any other mix.",
            "**Default** strips EXIF, GPS, IPTC and XMP, and keeps the colour profile and the AI workflow: a resized ComfyUI PNG still opens its workflow in ComfyUI. Opening another image goes back to Default; a preset carries its own choice.",
            "A switch is disabled, with a note, when the output format cannot carry the section: a ComfyUI graph requires PNG output.",
            "**Always:** the embedded EXIF thumbnail is dropped, orientation is baked into the pixels, and C2PA content credentials are stripped, because the signature binds the original pixels. Stripping IPTC also drops the EXIF artist and copyright. An HDR gain map is not written.",
            "**Copy** on every section, **Copy Prompt** and **Export…** on an AI workflow, **Copy All** and **Export All…** (JSON) in the **…** menu. They work whatever the switches say.",
            "SnapRescale does not edit metadata. For that, use ExifTool or Photos.",
        ]),
        Section(title: "Shortcuts", lines: [
            "**⌘O** open · **⌘S** save · **⇧⌘S** save as (when *Save next to the original without asking* is on; otherwise ⌘S opens the save panel) · **⌥⌘I** metadata inspector · **⌘,** settings · **⌘?** this help",
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
