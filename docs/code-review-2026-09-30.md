# SnapRescale general and defensive security code review

Reviewed 2026-09-30 against `4b187d90e538168a8cd8621bff79c2184de42f45`.

This is a fresh review of the current checkout, covering correctness, data
integrity, privacy, input validation, resource use, and the metadata milestone.
The current PRD and explicit product decisions govern the assessment. Earlier
reviews are historical context, not evidence that a current defect exists.

**Recommendation: address the two P1 findings before releasing the metadata
milestone.** The existing suite passes, but there are gaps around aggregate
metadata limits, interrupted saves, nested XMP filtering, and transfers between
metadata containers. The twelve findings below include recommended fixes and safe
regression checks. This document contains no exploit instructions or payloads.

Application code was not changed. The pre-existing untracked `.claude/` and
`.kilo/` directories were excluded from the review and left untouched.

## Scope and priorities

The review covers `RescaleKit`, the SwiftUI session and inspector, presets and
settings, the CLI harness, entitlements, and build/release configuration. The
main trust boundary is an image supplied by a user or another application:
its pixels, compressed text, metadata structures, and declared dimensions are
untrusted. The assets to protect are application availability, existing files,
accurate exported images and metadata, and privacy choices made before sharing.

P1 means high impact and recommended remediation before release. P2 means a
concrete defect to fix in the next corrective work. P3 means a lower-impact
correctness issue. These are remediation priorities, not CVSS scores.

| ID | Priority | Area | Finding | Evidence |
|---|---|---|---|---|
| S1 | P1 | Availability | Metadata limits apply per element, not per image | Runtime and source |
| G1 | P1 | File integrity | A failed replacement save can destroy the existing file | Runtime write primitive and source |
| S2 | P2 | Privacy | Nested XMP fields escape section filtering | Runtime output round trip |
| S3 | P2 | Privacy / disclosure | PNG text can be retained without appearing in the inspector | Runtime output round trip |
| G2 | P2 | Metadata integrity | PNG generation parameters disappear in JPEG/TIFF despite Keep | Runtime output round trip |
| S4 | P2 | Input validation | Source area can overflow in the CLI and public solver | Runtime |
| G3 | P2 | Metadata integrity | Extended XMP fragments are merged without association checks | Runtime and source |
| G4 | P2 | Preview fidelity | Transparent crop previews disagree with JPEG output | Source; encoder behavior checked |
| G5 | P3 | Export naming | AI export cache retains the previous source's filename | Isolated app-helper check |
| G6 | P2 | Export selection | Repeated AI payloads can share filenames and view IDs | Benign kit check and source |
| G7 | P3 | Readable metadata | Escaped A1111 settings are parsed incorrectly | Benign kit check |
| G8 | P2 | Capability reporting | Fallback XMP is shown as keepable but cannot be written | Existing test and source |

## Defensive security findings

### S1 — P1: Bound total metadata expansion before retaining it

Locations: [PNGScanner.swift:37](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PNGScanner.swift:37),
[PNGScanner.swift:75](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PNGScanner.swift:75),
[PNGScanner.swift:114](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PNGScanner.swift:114),
[XMPScanner.swift:226](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPScanner.swift:226).

The PNG scanner retains every decoded text chunk. Its 64 MiB inflation limit
applies to one stream, with no shared decoded-byte or chunk-count budget. The
HEIF XMP path similarly bounds individual extents but not the assembled packet.
Small pixel dimensions and small on-disk size therefore do not bound metadata
allocation. Stripping metadata on export does not avoid parsing it on import.

**Evidence and effect:** A bounded check of a small valid PNG decoded its pixels
successfully while `ImageMetadata.inspect` retained 128 MiB of text. A separate
scanner-level HEIF check showed assembled metadata substantially exceeding the
input size. The latter was not a full HEIF image-load test. These establish
allocation amplification; an out-of-memory termination was not induced.
Opening an untrusted file can exhaust resources before the user can save it.

**Recommended fix:** Pass a shared per-image metadata budget through scanning,
inflation, packet assembly, and decoding. Limit element counts as well as
decoded bytes; check remaining capacity before allocation or append. Enforce
the inflation ceiling before accepting `Z_STREAM_END`, where the current code
returns before checking the final size. Expose a clear truncated/skipped status
so the inspector and Keep controls do not imply complete preservation.

**Safe regression check:** Use deliberately small test budgets and harmless
text. Assert that several individually legal elements cannot exceed the total,
and cover final-stream completion, joined extents, and large uncompressed text.

### S2 — P2: Apply privacy filtering to every XMP descendant

Locations: [XMPWriter.swift:79](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPWriter.swift:79),
[XMPWriter.swift:132](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPWriter.swift:132).

`CGImageMetadataCopyTags` supplies top-level tags, and the writer constructs
paths only as `prefix:name`. It applies namespace-based privacy rules and
dimension/orientation fixes to those tags without inspecting descendants of a
kept structured property. PRD §10.3 promises that mirrored data follows its
section switch.

**Evidence and effect:** With XMP kept and GPS stripped, a saved and reloaded
JPEG removed a top-level GPS property but retained a nested GPS property inside
a custom RDF structure. Nested thumbnail content also remained. This is a
privacy-policy gap for structured XMP; the result does not establish that an
EXIF thumbnail survives or that Finder displays the nested XMP image. Default
and Strip all do not retain the source XMP packet, so this specific filtering
path does not apply.

**Recommended fix:** Enumerate the complete metadata tree, including structures
and arrays, using full paths and namespace identities. Apply strip rules and
output fixups to descendants. Collect removal paths before mutating the tree,
and remove subtrees without invalidating traversal.

**Safe regression check:** Round-trip benign structured and array-valued XMP
with placeholder GPS, thumbnail, orientation, and dimension values. Verify
removal/fixups at every depth while unrelated custom fields remain intact.

### S3 — P2: Show every PNG text chunk that Keep may retain

Locations: [PNGSplicer.swift:18](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PNGSplicer.swift:18),
[ImageMetadata.swift:303](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/ImageMetadata.swift:303).

The splicer classifies several keywords as workflow data regardless of their
contents. Detection and inspector population use stricter recognition rules.
Consequently, some chunks are eligible for default AI retention even when the
file has no detected AI provenance, payload, or AI section in the inspector.

**Evidence and effect:** A plain PNG containing benign private-note text under
a retained keyword had no AI section, yet that text survived default PNG
export. This is an undisclosed-retention issue. It is not a Strip all bypass:
Strip all disables the splicing path. The existing tests intentionally retain
these keywords without validating their contents, so the remedy must reconcile
the UI with that policy rather than silently redefine it.

**Recommended fix:** Derive inspection and retention from one classification
result. If unknown tool-keyword text is intentionally kept, display it as an
unrecognized AI candidate, explain that it will be retained, and expose the AI
switch. Ensure the summary describes the actual retained data.

**Safe regression check:** For each retained keyword, cover both recognized
payloads and ordinary text. Assert that every retained chunk is disclosed and
that selecting Strip removes it.

### S4 — P2: Validate source area before multiplying dimensions

Locations: [main.swift:33](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/rescale/main.swift:33),
[main.swift:108](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/rescale/main.swift:108),
[PixelSize.swift:15](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PixelSize.swift:15),
[Solver.swift:77](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Solver.swift:77).

The CLI accepts positive dimensions individually representable as `Int`.
`PixelSize.pixelCount` then multiplies them without checking area overflow.
CLI source reporting and the scale solver can reach this operation before
output validation. Output clamping does not make source arithmetic safe.

**Evidence and effect:** The freshly built CLI and a production-kit scale call
both terminated with signal 5 for oversized synthetic source dimensions.
This is established for CLI/API input, not for a decoder-produced image. The
public solver's nontrapping contract therefore has an uncovered boundary.

**Recommended fix:** Validate dimensions and area using checked multiplication
before solving or reporting. Make the public solver handle rejected/oversized
sources consistently with its stated contract; fixing only CLI parsing leaves
API callers exposed. Also require exactly two valid original components in
composite numeric parsers, rather than dropping invalid components with
`compactMap`.

**Safe regression check:** Exercise representable and overflowing area
boundaries and malformed components through both the public API and CLI.
Assert a defined error or safe result, never a process trap.

## General correctness and data integrity findings

### G1 — P1: Make replacement saves transactional

Locations: [Session.swift:483](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:483),
[FolderAccess.swift:28](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/FolderAccess.swift:28),
[MetadataInspector.swift:258](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/MetadataInspector.swift:258).

Image saves and metadata exports call `Data.write(to:)` without atomic
replacement. When a user confirms replacing an existing file, the write can
truncate that file before all new bytes have reached disk. Encoding successfully
in memory does not protect the subsequent file write.

**Evidence and effect:** An isolated failure-injection check of this exact
Foundation write mode returned an error after replacing an existing sentinel
file with a partial output. The app would display an error after the original
contents were already lost. This was a write-primitive check, not a save-panel
UI test. Explicitly confirmed replacement remains accepted product behavior;
the defect is destruction on a failed save.

**Recommended fix:** Centralize output writes in a helper that completes a
temporary write and atomically replaces the destination only on success.
Respect security-scoped/save-panel grants and verify the approach in the
sandboxed build. Clean up temporary files on failure and publish `lastSaved`
only after commit. Preset writes already use `.atomic`; cover image and
metadata writes too.

**Safe regression check:** Inject a write failure against a disposable test
destination and assert that its original bytes remain unchanged. Also check
successful replacement, new-file creation, and both sandbox save paths.

### G2 — P2: Carry PNG generation parameters into the promised EXIF container

Locations: [MetadataCapability.swift:74](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataCapability.swift:74),
[MetadataWriter.swift:30](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataWriter.swift:30),
[Renderer.swift:146](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/Renderer.swift:146),
[PNGSplicer.swift:52](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/PNGSplicer.swift:52).

The capability layer enables Keep for PNG generation parameters when exporting
to JPEG, HEIC, or TIFF, and says they are kept in EXIF UserComment. The writer
only recovers AI text already present in the source EXIF/TIFF dictionaries.
There is no transfer from PNG text chunks, and the splicer handles PNG outputs
only.

**Evidence and effect:** The existing A1111 PNG fixture retained its payload
when exported as PNG but lost it when exported as JPEG or TIFF under Default,
which keeps AI data. The capability and note still promised preservation.
HEIC has the same missing code path, but its encoder was unavailable in the
restricted probe environment; no HEIC runtime result is claimed.

**Recommended fix:** Give the writer access to classified AI payloads and
transfer supported PNG parameters into EXIF UserComment when appropriate.
Define conflict handling for multiple candidate payloads. If a combination
cannot be preserved, disable Keep with an accurate note rather than advertising
a transfer that does not occur.

**Safe regression check:** Use the existing PNG fixture for each supported
output format and both AI policies, independently of the EXIF policy. Verify
the full parameter text after reloading; cover conflicting candidates.

### G3 — P2: Validate Extended XMP association and assembly

Locations: [XMPScanner.swift:61](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPScanner.swift:61),
[XMPScanner.swift:69](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPScanner.swift:69),
[ImageMetadata.swift:193](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/ImageMetadata.swift:193).

The JPEG scanner skips the extension GUID and advertised total length, sorts
fragments by offset, and concatenates them. It does not verify that the fragments
belong to the main packet or form a complete, non-overlapping packet.

**Evidence and effect:** A bounded metadata check exposed an unrelated extension
field through `ImageMetadata.inspect`. ImageIO also accepted the sample, but the
application performs its own association and merge, so relying on ImageIO does
not supply the missing validation. Inspector behavior was checked at runtime;
saved-XMP behavior follows from the writer's extended-tag merge and was not
checked in an output round trip. Both can represent content that does not
belong to the main packet. Association rules are specified in
[Adobe's XMP storage specification](https://github.com/adobe/XMP-Toolkit-SDK/blob/main/docs/XMPSpecificationPart3.pdf), page 15.

**Recommended fix:** Select only the extension group referenced by the main
packet, validate a consistent total size within the metadata budget, and require
valid, complete offset coverage. Ignore unrelated or incomplete groups and
report skipped metadata. Keep merge behavior deterministic.

**Safe regression check:** Cover matching and mismatched associations, fragments
arriving in different orders, missing portions, overlaps, and inconsistent
lengths using short benign packets.

### G4 — P2: Match transparent crop previews to opaque output

Locations: [PreviewView.swift:29](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/PreviewView.swift:29),
[PreviewView.swift:71](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/PreviewView.swift:71).

Crop draws the alpha-bearing preview directly over the window's adaptive page
background. JPEG output flattens transparency over white. Pad has output-aware
background handling, but crop does not. Consequently a transparent or translucent
source region can look different from the saved file, especially in dark mode.
This violates the preview-fidelity requirement in PRD §7.

**Evidence and effect:** The encoder's white JPEG flattening was checked with a
normal transparent source. The discrepancy is established by source inspection
of the preview; no screenshot/UI comparison was performed. Stretch has the same
rendering pattern, although the ordinary UI exposes Crop and Pad.

**Recommended fix:** Share the effective alpha/background policy between preview
and rendering in every fit mode, considering source alpha as well as pad alpha.
Draw the correct opaque background inside the image region, or generate a small
format-aware preview.

**Safe regression check:** Compare a normal translucent image preview against its
decoded JPEG and PNG outputs in light and dark appearances, for crop and pad.

### G5 — P3: Include source identity in the AI export cache key

Locations: [MetadataInspector.swift:365](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/MetadataInspector.swift:365),
[MetadataExport.swift:140](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataExport.swift:140).

`AIDetails` invalidates its cache only when `ImageMetadata` changes. Its cached
exports also depend on the source basename. Replacing an image with a renamed
copy that carries identical metadata reuses the previous filenames.

**Evidence and effect:** An isolated check using the current helper and production
kit returned the previous source's workflow filename for the second source; its
freshly computed export had the correct new filename. The payload is unchanged,
but the menu and save suggestion misidentify the current image. The helper check
did not drive the UI.

**Recommended fix:** Include the source URL/basename in the cache key, or cache
only metadata-derived content and generate filenames from the current source.
Use source identity consistently when resetting inspector state.

**Safe regression check:** Replace one source with another basename and identical
metadata; assert that every export suggestion uses the current basename.

### G6 — P2: Give every AI payload a distinct export identity

Locations: [MetadataExport.swift:13](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataExport.swift:13),
[MetadataExport.swift:117](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataExport.swift:117),
[MetadataInspector.swift:215](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/MetadataInspector.swift:215).

Export naming resolves collisions by adding the AI source name. Repeated
payload names from the same source still collide, and `MetadataExport.id` is
the filename. Distinct choices then enter SwiftUI `ForEach` with duplicate
identities and indistinguishable save suggestions.

**Evidence and effect:** A benign kit check produced two distinct same-source
workflow exports but only one unique filename and ID. The duplicate identity
is confirmed; no UI claim about which button SwiftUI displays or selects is
made. The menu cannot reliably identify every payload, and exporting successive
choices suggests the same destination.

**Recommended fix:** After source qualification, add deterministic occurrence
suffixes or location identifiers to remaining filename collisions. Give every
payload a stable unique identity independent of its display name. Ensure the
primary choice refers to that same identity.

**Safe regression check:** Assert distinct names and IDs for repeated workflow
entries and parameters from multiple metadata locations. Verify that each
export maps to its own unchanged bytes.

### G7 — P3: Respect escaping in quoted A1111 settings

Locations: [AIWorkflowSummary.swift:112](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/AIWorkflowSummary.swift:112),
[AIWorkflowSummary.swift:123](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/AIWorkflowSummary.swift:123).

The settings tokenizer toggles quotation state for every quote, including
escaped quotes. It also removes surrounding quotes without decoding string
escapes. Legal quoted values containing quotation marks and commas can be
split mid-value or displayed with escape sequences.

**Evidence and effect:** A benign in-memory check showed a truncated model name
for a valid quoted setting. This affects the readable AI summary, including
text copied from it; it does not corrupt the raw retained/exported payload.

**Recommended fix:** Make tokenization escape-aware and decode quoted strings
using the serialization's string rules. Preserve the existing behavior that
omits duplicate keys with conflicting values.

**Safe regression check:** Cover quoted commas, escaped quotation marks,
backslashes, and escaped newlines, alongside unquoted values and duplicate keys.

### G8 — P2: Make XMP Keep capability depend on the captured source data

Locations: [ImageMetadata.swift:198](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/ImageMetadata.swift:198),
[XMPWriter.swift:59](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/XMPWriter.swift:59),
[MetadataCapability.swift:20](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/MetadataCapability.swift:20).

For containers not walked by the packet scanner, inspection falls back to
ImageIO fields without retaining an XMP packet. The writer requires a packet,
but capability reporting considers only the destination format for XMP. It
therefore enables Keep on conversion to a writable format even though there is
nothing the writer can use to preserve the source packet.

**Evidence and effect:** The passing fallback GIF test explicitly verifies
`hasXMP` with no captured packet and a visible rating field. The writer's guard
then establishes that the source XMP will not be written. A new output round
trip was not performed for this item. The roadmap already discloses lack of
XMP carry-over for GIF/RAW/PSD; the defect here is the enabled Keep control and
missing source-specific loss warning, not an undisclosed roadmap feature gap.

**Recommended fix:** Preserve a filterable immutable fallback metadata tree, or
disable XMP Keep with an accurate note when only display fields were captured.
Derive source-aware capability from the representation available to the writer.

**Safe regression check:** Extend the existing fallback GIF test with supported
output conversion. Require either preserved metadata or an explicit disabled
Keep state explaining the limitation.

## Additional hardening work

These are source-backed resource risks with limited runtime verification. They
are separate from the twelve findings above so their evidence is not overstated.

- **Budget native image decoding.** [SourceImage.swift:44](/Users/francescolardieri/Projects/MyProjects/Rescale/RescaleKit/Sources/RescaleKit/SourceImage.swift:44)
  requests an immediate cached thumbnail at native resolution before checking
  any application source-memory limit. Target render limits apply later and
  cannot bound this allocation. Header-only inspection confirmed a highly
  compressed source declaring hundreds of millions of pixels; full decoding
  was deliberately avoided. Check dimensions, bit depth, and estimated decoded
  bytes before requesting pixels, with a defined rejection/downsampling policy.
- **Bound replacement loads.** [Session.swift:268](/Users/francescolardieri/Projects/MyProjects/Rescale/SnapRescale/Sources/SnapRescale/Session.swift:268)
  starts a new detached decode for every accepted load. The generation check
  correctly prevents stale results from committing, but obsolete decodes still
  run to completion. Rapid replacement can accumulate simultaneous pixel and
  metadata allocations. Use one active decode and one replaceable pending
  request, while retaining the generation guard. No memory benchmark was run.

## Validation, strengths, and limitations

| Check | Result |
|---|---|
| Fresh `swift test --package-path RescaleKit` with isolated build/cache paths | 235 tests in 19 suites passed |
| Fresh `swift build --package-path SnapRescale` with isolated build/cache paths | Passed |
| Solver boundary scan of 1,512,777 validated requests | No solved target exceeded the target pixel limit |
| Transparent-source JPEG rendering in crop, pad, and stretch | Formerly transparent regions correctly became white |
| Metadata keep/strip and transfer checks | Results recorded individually above |
| Failure-injection check of the save write mode | Existing disposable destination was partially overwritten on error |
| AI export cache check | Stale filename confirmed |
| Benign AI export and readable-settings checks | Duplicate export IDs and quoted-value parsing errors confirmed |

The implementation has useful safeguards: positive/finite size validation,
target render limits, validated preset loading, stale-load generation checks,
serialized/coalesced output estimation, honest fallback from unwritable formats,
and explicit metadata policies. The sandbox entitlements grant user-selected
file access and do not grant network access. No application network client or
workflow execution path was identified in the inspected code. The review found
no confirmed arbitrary-code-execution or sandbox-escape issue; that is not a
guarantee that none exists.

The current fixes for ordinary numeric input, extreme aspect handling, preset
validation, and format fallback were not relisted as unresolved historical
findings. First-frame import, a disposable single-image session, and confirmed
replacement through the save panel are accepted current behavior. Known CMYK,
HDR, and ICC-format limitations are already disclosed in the roadmap.

Checks used temporary files and builds outside production sources. Some isolated
executables encountered restricted-environment type-registration behavior that
rejected valid PNGs before import. Metadata round trips therefore used ImageIO
fixture loading to construct `SourceImage`, exercising the production scanner,
renderer, and writer unchanged. An ordinary alpha-render check used approved
platform access. These environment limitations were not classified as app bugs.

This was not a full UI walkthrough, sandboxed export/relaunch test, release
archive or notarization check, real-camera/tool corpus, dependency-history or
secret-history audit, or audit of Apple's decoders. No deployment or publication
was performed. After remediation, run the focused regression checks above and
the existing suite, then verify save/metadata export in the sandboxed release
build before shipping.
