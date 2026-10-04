# Developer documentation consistency review — 2026-10-03

Reviewed against `fa50d19593e2574692aa1aef7e617d3ccd5e3b47`.

**Result: four P2 and six P3 documentation findings.** The main gaps concern
file-replacement guarantees, preset replay, metadata completeness, and the
build/test instructions. Other findings concern numerical behavior, shortcuts,
metadata detection, the UI workaround, and roadmap status.

This is a review, not a documentation rewrite or implementation change. Only
this report was added. Where a requirement is stronger than the implementation,
the recommendation is to record the gap and make an explicit product decision;
weakening the requirement is not automatically the right fix.

## Scope and method

The codebase graph was refreshed successfully with `index_repository` in full
mode **before review**, even though an index already existed. Discovery used
the refreshed graph and findings were verified against the active checkout.
Old `.kilo` symbols still appeared in some graph results and were excluded.
Three parallel review tracks covered metadata/rendering, build/release, and
session/geometry; findings were consolidated and checked against source.

Reviewed README, PRD, roadmap, release/App Store instructions, changelog,
metadata references and fixture notes, the macOS layout-workaround document,
and related Help/in-app descriptions. Dated review reports and historical
release entries were treated as historical evidence, not current specifications.
External release availability and upstream third-party behavior were not audited.

P2 denotes a misleading contract or instruction that can affect data handling,
reproducibility, or a developer's workflow. P3 denotes lower-impact inaccuracies
or stale guidance. These priorities describe documentation remediation.

| ID | Priority | Documentation mismatch |
|---|---|---|
| D1 | P2 | No-overwrite guarantee omits the nonexclusive filesystem fallback |
| D2 | P2 | Presets do not capture every setting or replay framing |
| D3 | P2 | Complete inspection/archive wording omits metadata read limits |
| D4 | P2 | README test commands fail when followed in sequence |
| D5 | P3 | Size-view and snapping descriptions promise stronger invariants |
| D6 | P3 | Shortcut documentation exceeds implemented availability |
| D7 | P3 | C2PA reference conflates possible storage with implemented detection |
| D8 | P3 | ICC reference/fixture notes describe an obsolete origin model |
| D9 | P3 | The workaround guide misdescribes how clicks are deferred |
| D10 | P3 | Current roadmap status contradicts merged code and history |

## D1 — Qualify the implemented no-overwrite guarantee

**Documentation:** [PRD §11](PRD.md#L543) says nothing is ever silently
overwritten and replacement requires save-panel confirmation.
[CHANGELOG](../CHANGELOG.md#L58) says silent saves and the CLI never replace a
file that appeared after name selection.

**Implementation:** [SafeWrite.create](../RescaleKit/Sources/RescaleKit/SafeWrite.swift#L23)
uses exclusive rename where supported. On `ENOTSUP`, `EINVAL`, or `EXDEV`,
[the fallback](../RescaleKit/Sources/RescaleKit/SafeWrite.swift#L46) checks
existence and then calls `replaceItemAt`, leaving a collision window. Its own
comment explicitly acknowledges the limitation on exFAT.

**Why it matters:** Developers can interpret the prose as a guarantee across
all supported save destinations. [The exFAT release check](RELEASING.md#L50)
verifies sequential `_2` naming, which does not establish concurrent collision
protection.

**Recommended correction:** Preserve unconditional no-overwrite as the intended
contract if desired, but explicitly identify the unsupported-volume gap.
Qualify the changelog's claim until implementation meets it everywhere, and
distinguish sequential suffix checks from exclusive-creation checks in the
release checklist. No new filesystem-race experiment was performed in this review.

**Owner comment:** Agreed, and close the window rather than only qualify the
text. Where the exclusive rename is unsupported, the fallback reserves the name
with `open(O_CREAT | O_EXCL)` (exFAT refuses a taken name with `EEXIST`), moves
to the next name when it is taken, then replaces the reservation with the staged
file. PRD §11, the CHANGELOG and RELEASING step 4 then say what holds and what
the step checks (#56).

## D2 — Document the actual preset schema and replay boundary

**Documentation:** [PRD §12](PRD.md#L561) calls a preset a bundle of every
setting, including resampling, destination and template; [the same section](PRD.md#L571)
says any edit becomes Custom and the preset replays exactly.
[Help](HELP.md#L42) and [in-app Help](../SnapRescale/Sources/SnapRescale/AboutAndHelp.swift#L89)
repeat the every-setting claim.

**Implementation:** [Preset.CodingKeys](../RescaleKit/Sources/RescaleKit/Preset.swift#L34)
contains name, aspect, size, multiple, fit, padding colour, format, quality and
metadata. There is no crop/pad anchor, resampling choice, destination or template.
[Session.apply/currentPreset](../SnapRescale/Sources/SnapRescale/Session.swift#L51)
neither restores nor stores framing. Loading a new image resets the anchor to
centre; changing framing alone does not change the preset comparison.

**Why it matters:** A developer implementing preset interchange or replay could
expect nonexistent JSON fields or composition reproducibility. An off-centre
crop is not restored by the saved preset.

**Recommended correction:** Enumerate the current fields, state that framing
and app preferences are excluded, and label destination/template/resampling as
future schema work. Say changes to *stored preset settings* select Custom.
If exact composition replay is required, retain that as an explicitly unmet
requirement rather than describing it as implemented.

**Owner comment:** Agreed. Document the stored fields; framing and app
preferences are not part of a preset, and destination, template and resampling
are future schema work. Exact composition replay is not a requirement (#47).
Found while checking this: a preset with a fractional quality percent, or a
scale that does not survive ×100 and ÷100, selects Custom by itself; fixed in
`Session` (#60).

## D3 — Define what inspection, Keep, and Export All can preserve

**Documentation:** [PRD §10.2](PRD.md#L454) says the inspector lists everything
the source carries. [§10.5](PRD.md#L528) describes Export All as an archive
before stripping. [The metadata reference](reference/image-metadata.md#L72)
describes carrying source PNG text without explaining read exclusions.

**Implementation:** [MetadataBudget](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L43)
defaults to 64 MiB of charged retained scanner data, 4,096 elements and 128 MiB
of inflation work. These are scanner limits, not an overall process-memory
ceiling. Skipped metadata is not available for inspection or output.
[Export All](../RescaleKit/Sources/RescaleKit/MetadataExport.swift#L41) serializes
captured section fields, not original container metadata; it does not serialize
the sections' loss notes. The passing
[skippedChunkIsNotCarriedByKeep test](../RescaleKit/Tests/RescaleKitTests/MetadataBudgetTests.swift#L293)
confirms a skipped workflow is absent even under a keep policy.

**Why it matters:** Developers can mistake Export All for a complete backup or
assume Keep can preserve content the loader intentionally omitted. The original
image remains necessary when complete preservation matters.

**Recommended correction:** Specify “metadata successfully read within supported
formats and resource limits.” Document the defaults, skip notices, and their
effect on Keep and exports. Describe Export All as an export of captured fields,
not a lossless metadata archive. Keep the defensive limits; this finding does
not recommend removing them.

**Owner comment:** Agreed. The limits stay (review 2026-10-03, S1–S3); the
docs state them, the skip note and their effect on Keep, and describe Export All
as a JSON of the fields shown, not a lossless archive (#48).

## D4 — Make the README test commands independent of directory changes

**Documentation:** [README building commands](../README.md#L69) run
`cd RescaleKit && swift test`, followed by
`swift test --package-path SnapRescale`.

**Observed result:** Following the sequence leaves the shell in `RescaleKit`.
The second command exits 1 because it looks for
`RescaleKit/SnapRescale`, which does not exist. Both packages are siblings.

**Recommended correction:** Run both commands from the repository root:

```sh
swift test --package-path RescaleKit
swift test --package-path SnapRescale
```

Both corrected commands were run successfully during this review: 307 engine
tests and 9 app tests passed.

**Owner comment:** Agreed. Fixed now: the developer section is not release
copy, which waits for the upload (#54).

## D5 — Explain integer rounding and snapping accurately

**Documentation:** [PRD §5](PRD.md#L114) says changing size views cannot move
dimensions at multiple 1. [Help](HELP.md#L18) and
[in-app Help](../SnapRescale/Sources/SnapRescale/AboutAndHelp.swift#L77) say the
typed number is kept while only the derived side moves.

**Implementation:** [switchSizeKind](../SnapRescale/Sources/SnapRescale/Session.swift#L394)
transfers solved dimensions and solves again. [Solver.snap](../RescaleKit/Sources/RescaleKit/Solver.swift#L126)
still rounds to integer pixels at multiple 1. At larger multiples,
[holdPinnedAxis](../RescaleKit/Sources/RescaleKit/Solver.swift#L106) first snaps
the typed axis, then holds that snapped value.

**Verified examples with the current CLI:**

| Source and request | Result |
|---|---|
| 6000×4000, Original, width 1031, multiple 1 | 1031×687 |
| Same source, Original, height 687, multiple 1 | 1030×687 |
| Same source, 16:9, width 1500, multiple 8 | 1504×848 |

The first two reproduce the inputs used by a Width-to-Height view change;
the actual UI interaction was not exercised. The CLI explicitly reports the
1500-to-1504 snap.

**Recommended correction:** Say integer rounding can change a derived dimension
even at multiple 1, and the typed axis is first rounded to a legal multiple.
PRD §6 already explains the latter correctly; align both Help copies with it.
If invariant view switching remains a product requirement, mark it unmet.

**Owner comment:** Agreed. Invariant view switching at ×1 is not a
requirement: the docs say whole-pixel rounding can move a side by a pixel, and
that a typed number which is not a multiple moves to the nearest one (#49).

## D6 — Separate implemented shortcuts from desired shortcuts

**Documentation:** [Help's shortcut list](HELP.md#L78), also in
[in-app Help](../SnapRescale/Sources/SnapRescale/AboutAndHelp.swift#L104), lists
⇧⌘S without qualification. [PRD §5](PRD.md#L183) and
[the ladder decision](PRD.md#L674) specify ⌘1–⌘5.

**Implementation:** [SnapRescaleApp.commands](../SnapRescale/Sources/SnapRescale/SnapRescaleApp.swift#L40)
registers ⇧⌘S only when silent next-to-original saving is enabled. The
[ladder picker](../SnapRescale/Sources/SnapRescale/ControlsPanel.swift#L273)
has no number-key bindings; the current app's shortcut/key-handler search found
no implementation of the specified ladder shortcuts.

**Recommended correction:** State the preference condition for ⇧⌘S, and mark
ladder shortcuts as planned/unimplemented. The PRD already labels its removed
slider design as historical; do not revive that entire design to fix this text.
Shortcut availability was established from source, not a keyboard UI test.

**Owner comment:** ⇧⌘S stays tied to *Save next to the original without
asking*: in the default mode ⌘S already opens the save panel. ⌘1–⌘5 and the
arrow-key steps were dropped with the slider (2026-09-06) and are recorded as
dropped, not planned (#50). Found while checking this: ⌘W closes no window,
because replacing the Save menu group also removed File ▸ Close; fixed (#59).

## D7 — Separate C2PA storage possibilities from detection support

**Documentation:** [The metadata catalogue](reference/image-metadata.md#L3)
presents itself as how the loader sees metadata. Its
[C2PA row](reference/image-metadata.md#L49) lists JPEG, PNG and HEIC `uuid`
storage together with a C2PA badge.

**Implementation:** [ImageMetadata.inspect](../RescaleKit/Sources/RescaleKit/ImageMetadata.swift#L179)
adds C2PA provenance only for PNG `caBX` and JPEG APP11/JUMBF. No HEIC C2PA
detection branch was found.

**Recommended correction:** Use separate columns for known container locations
and implemented detection, marking HEIC detection unsupported/planned. Explain
that marker detection is not signature verification. This is a static support
matrix finding; no signed HEIC file was tested and no external C2PA format
specification was revalidated.

**Owner comment:** Agreed. Found while checking this: JPEG detection accepted
any APP11 JUMBF segment, JPEG XT included, not only Content Credentials; it now
requires the C2PA label (#58). The reference is rewritten after that fix (#51).

## D8 — Update ICC reference and fixture expectations to three states

**Documentation:** [The ICC reference row](reference/image-metadata.md#L23)
describes `ProfileName` as the detection mechanism. The
[fixture README](../RescaleKit/Tests/RescaleKitTests/Fixtures/metadata/README.md#L49)
says its sRGB PNGs and JPEGs have assumed `iccOrigin`.

**Implementation:** [ICCOrigin](../RescaleKit/Sources/RescaleKit/ICCScanner.swift#L7)
distinguishes embedded, tagged and assumed. PNG `sRGB` is
[explicitly tagged](../RescaleKit/Sources/RescaleKit/ICCScanner.swift#L36), not
assumed. Only an embedded profile earns the ICC badge; a profile name alone
does not. The current
[tagged-PNG fixture test](../RescaleKit/Tests/RescaleKitTests/MetadataReadableTests.swift#L429)
passed and asserts that distinction.

**Recommended correction:** Explain container-based origin detection and all
three states. Split tagged PNGs from assumed JPEGs in the fixture notes. PRD
§10.1 already describes the embedded-only badge rule correctly.

**Owner comment:** Agreed. Found while checking this: a GIF or BMP without a
profile, and a file the scanner cannot parse, showed the ICC badge, because
ImageIO names sRGB for nearly every image. GIF and BMP are now walked and an
unparsable file counts as assumed (#57); the reference describes the result
(#51).

## D9 — Match the UI-workaround recipe to the actual event paths

**Documentation:** [Workaround we ship](apple-feedback-macos27-form-width.md#L44)
says clicks, gestures and sliders use a main-queue hop, reserving the default
run-loop plus main-actor hop for open panels, menus and Settings.

**Implementation:** Discrete button clicks, such as
[the step buttons](../SnapRescale/Sources/SnapRescale/ControlsPanel.swift#L225),
use `deferred`: [a default-mode run-loop block followed by a Task hop](../SnapRescale/Sources/SnapRescale/Deferred.swift#L10).
Continuous crop dragging uses
[deferredLive](../SnapRescale/Sources/SnapRescale/PreviewView.swift#L182), whose
[implementation](../SnapRescale/Sources/SnapRescale/Deferred.swift#L24) uses the
main queue. The same distinction exists in the local `v1.1-build3` tag, so this
is not merely a later change to a correctly versioned document.

**Recommended correction:** Describe discrete controls with `deferred` and
continuous interactions with `deferredLive`. Retain the two-hop rationale and
the AppKit drop lifecycle explanation. A developer following the current prose
could select the wrong helper. No new macOS layout reproduction was attempted.

**Owner comment:** Agreed: `deferred` for discrete controls, `deferredLive`
for continuous ones, with the header of `Deferred.swift` and the comment in
`PreviewView` to match (#52).

## D10 — Reconcile current roadmap status with the checkout

**Documentation:** [ROADMAP's metadata status](ROADMAP.md#L27) still calls wave
3/PR #28 “in review.” [Its batch row](ROADMAP.md#L87) says a few images are
covered by multiple windows in v1.1, although
[multiple windows](ROADMAP.md#L63) is also labeled “Also next.”

**Repository evidence:** Local merge commit `4b187d9` merges PR #28 and is an
ancestor of the reviewed HEAD. The current app still creates
[one main Window with Session.shared](../SnapRescale/Sources/SnapRescale/SnapRescaleApp.swift#L9).
The top-level M5/current headings also coexist with later text describing
Metadata as the next milestone, without one clear current-state summary.

**Recommended correction:** Mark wave 3 as merged, leave release/sandbox
acceptance separately pending where appropriate, and remove the claim that
multiple windows belongs to the already shipped v1.1. Keep dated M5 submission
notes as history under an explicitly historical heading. This conclusion uses
local commits and code; it does not assert current App Store or remote issue status.

**Owner comment:** Agreed. The current milestone is the Metadata release,
version 1.2 (decided 2026-10-04): merged, not released, gated by the sandbox
checks in RELEASING.md (passed on fa50d19 on 2026-10-03, repeated on the
release build before upload). Multiple windows (#35) stays later; the formats
and encoding release becomes 1.3 (#53).

## Smaller cleanup items

- [PRD §11](PRD.md#L553) says the filename-template mechanism already ships.
  [OutputNaming](../RescaleKit/Sources/RescaleKit/Renderer.swift#L197) implements
  a fixed basename/dimensions/counter scheme, not configurable template
  evaluation. Describe that fixed scheme as current and the template engine as
  future work.
- [The CLI file header](../RescaleKit/Sources/rescale/main.swift#L1) still says
  no pixels are written, although its `--write` path renders and saves. README
  and PRD §13 already describe this correctly.
- The design ideas at the end of
  [the ComfyUI reference](reference/comfyui-node-review.md#L101) should be
  labeled historical proposals. Current PRD/roadmap decisions already supersede
  or defer its different megapixel convention, size modes and resampling ideas.

**Owner comment:** Agreed, all three (#54; the CLI header goes with #56, which
edits the same file). Also: Help's auto-quit wording becomes conditional, since
the app quits after saving only when it was launched to open that image (#54).

## Verified consistency and validation boundaries

- Build output locations, signing-mode branches, exact `UPLOAD=1` behavior,
  project version extraction, sandbox entitlements and the 5,940-case parity
  fixture agree with the build/release documentation inspected.
- Shipped preset values and the PRD's distinction between the current one-file
  CLI and proposed v2 CLI syntax agree with code.
- CoreGraphics high-quality interpolation, synthetic metadata fixtures,
  CMYK/Lab conversion, unsupported XMP carry-over and HDR/profile-stripping
  limitations are already disclosed. Synthetic fixtures do not disprove
  separately reported manual testing on real images.
- README's explicitly versioned 1.0 limitations, dated changelog entries and
  past review findings were not relisted as defects just because current code
  has changed. The October 3 code review has a resolution log acknowledging the
  filesystem fallback and outstanding sandbox validation.

| Check performed in this review | Result |
|---|---|
| Full codebase graph refresh before discovery | Succeeded |
| README directory/path sequence | Invalid second package path reproduced |
| `swift test --package-path RescaleKit` | 307 tests in 24 suites passed |
| `swift test --package-path SnapRescale` | 9 tests in 1 suite passed |
| Current-source CLI build and three solve-only checks | Confirmed D5 examples |
| Individual `zsh -n` checks for shell scripts | Passed |
| Local PR #28 merge ancestry and v1.1 workaround source | Verified |
| Report source-link/line and whitespace checks | Passed |

Existing tests and builds used normal local SwiftPM output directories; logs
were written under `/tmp`. No new tests or production code were added. No UI
walkthrough, signed sandbox save, exFAT race test, archive, notarization,
publication or deployment was performed. Passing tests verify the implemented
behavior; they do not turn the stronger documentation claims into guarantees.
