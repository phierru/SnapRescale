import Foundation
import UniformTypeIdentifiers

/// "Keep AI workflow" for PNG output (PRD §10.2, §10.4 step 3). ImageIO will
/// not write custom PNG text chunks, so the source's are put back into the
/// encoded file, byte for byte, just before `IEND`.
public enum PNGSplicer {
    /// Keywords that only an AI tool writes; carried whatever else the file holds.
    static let workflowKeywords: Set<String> = [
        "prompt", "workflow", "parameters", "fooocus_scheme", "invokeai_metadata", "invokeai_graph", "sd-metadata",
    ]
    /// Generic keywords NovelAI uses for its payload; carried only from a NovelAI file.
    static let novelAIKeywords: Set<String> = ["Software", "Comment", "Description", "Title", "Source"]

    /// The AI-provenance text chunks among `chunks`, in source order
    /// (`docs/reference/image-metadata.md` §3). Never `XML:com.adobe.xmp`: that
    /// belongs to the XMP switch. `caBX` (C2PA, always stripped) is not a text
    /// chunk and so never reaches here.
    public static func aiWorkflowChunks(in chunks: [PNGScanner.TextChunk]) -> [PNGScanner.TextChunk] {
        let found = Set(ImageMetadata.provenance(fromPNGChunks: chunks))
        return chunks.filter { chunk in
            if workflowKeywords.contains(chunk.keyword) { return true }
            if found.contains(.novelAI), novelAIKeywords.contains(chunk.keyword) { return true }
            if found.contains(.midjourney), chunk.keyword == "Description" { return true }
            return false
        }
    }

    /// `png` with `chunks` inserted immediately before `IEND`, each with its
    /// length and a fresh CRC, in the order given; every other byte is unchanged.
    /// Returns `png` unchanged when it is not a PNG, has no well-formed chunk
    /// run ending in `IEND`, or there is nothing to insert: a save never fails
    /// for the sake of a text chunk.
    public static func splice(_ chunks: [PNGScanner.TextChunk], into png: Data) -> Data {
        let chunks = chunks.filter { $0.raw.count >= 4 }
        guard !chunks.isEmpty, let iend = iendOffset(in: png) else { return png }
        let insert = chunks.reduce(into: Data()) { $0.append($1.encoded) }
        var out = Data(capacity: png.count + insert.count)
        out.append(png[png.startIndex..<iend])
        out.append(insert)
        out.append(png[iend...])
        return out
    }

    /// The post-encode step of `Renderer.produce`: carries the source's AI
    /// workflow into `encoded` when the policy keeps it, the output is PNG and
    /// the source is a PNG holding such chunks; otherwise `encoded` as it came.
    /// A keyword ImageIO already wrote is not written twice. Other formats get
    /// nothing here: A1111 parameters in the EXIF user comment ride with the
    /// EXIF writer.
    public static func keepingAIWorkflow(_ encoded: Data, from source: SourceImage, spec: RenderSpec) -> Data {
        guard spec.metadata.aiWorkflow == .keep,
              spec.format.resolvedType(for: source.type)?.conforms(to: .png) == true else { return encoded }
        let wanted = aiWorkflowChunks(in: source.metadata.pngTextChunks)
        guard !wanted.isEmpty else { return encoded }
        let written = Set(PNGScanner.textChunks(in: encoded).map(\.keyword))
        return splice(wanted.filter { !written.contains($0.keyword) }, into: encoded)
    }

    /// Index in `data` of the first byte of the `IEND` chunk (its length field).
    /// Nil unless the signature is followed by whole chunks up to an `IEND`.
    static func iendOffset(in data: Data) -> Data.Index? {
        guard data.count >= 8, Array(data.prefix(8)) == PNGScanner.signature else { return nil }
        var i = data.startIndex + 8
        while i + 12 <= data.endIndex {
            let length = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            if data[i + 4..<i + 8].elementsEqual(Array("IEND".utf8)) { return length == 0 ? i : nil }
            guard i + 12 + length <= data.endIndex else { return nil }
            i += 12 + length
        }
        return nil
    }
}
