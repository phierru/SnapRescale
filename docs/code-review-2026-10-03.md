# Code review and defensive security audit — 2026-10-03

Reviewed commit `829570149e47d47de16822944c50a036b2f3f3d3` on macOS 27.0.1
(26A434), Apple Swift 6.4, arm64. The worktree was clean before review.
Only this report was added; application code and tests were not changed.

**Result: five P2 findings**, covering incomplete metadata resource limits,
save-session lifecycle, and collision-safe output creation. Address these in
the next corrective release. No critical vulnerability was confirmed. Passing
tests do not cover the remaining boundaries identified here.

P2 means a concrete issue warranting correction; P3 observations below are
lower-priority maintenance or responsiveness work. These are engineering
priorities, not CVSS scores. This report contains no exploit instructions or
hostile payloads.

## Scope and method

Reviewed the current RescaleKit loading, scanner, metadata filtering, rendering,
solver and write paths; SwiftUI session, import, inspector export, presets and
folder grants; CLI output; and package, entitlement and release configuration.
Used the codebase knowledge graph for discovery and targeted source inspection
for verification. The graph also contains an old `.kilo` worktree: its symbols
were excluded from conclusions about the active checkout. Some call edges were
missing, so callers were verified from current source rather than inferred
solely from the graph.

The main trust boundary is user-supplied image content, including compressed
metadata and declared sizes. Relevant assets are availability, existing files,
metadata privacy choices, and accurate session/save status. Historical review
findings were checked against current implementations, not presumed unresolved.

| ID | Priority | Finding | Evidence |
|---|---|---|---|
| S1 | P2 | PNG budget omits auxiliary strings and retained raw chunks | Source and small scanner check |
| S2 | P2 | PNG element limit does not stop decompression work | Source |
| S3 | P2 | XMP budget is not enforced across all container paths | Source and small WebP scanner check |
| G1 | P2 | An old save can publish into, or quit, a newer image session | Source and event-order analysis |
| G2 | P2 | Silent save can replace a file created after name selection | Source and isolated write check |

## Findings

### S1 — Count all retained PNG metadata before allocating it

Locations: [PNGScanner.swift:106](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L106),
[PNGScanner.swift:116](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L116),
[PNGScanner.swift:135](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L135),
[PNGScanner.swift:145](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L145).

**Owner comment:** Agreed. Keep the 64 MiB ceiling as a true bound on what is
retained: charge raw copies, labels and decoded text, even though that leaves
less room for large uncompressed text. A damaged chunk is charged for its raw
bytes; when it does not fit it is skipped and reported, like any other chunk.

The scanner charges only the text body, using its pre-string-conversion byte
count. Keyword, language and translated-keyword strings are decoded outside
that accounting. Every accepted chunk also gets a complete owned `raw` copy.
A damaged compressed chunk consumes an element but zero bytes, although its raw
body is retained. Consequently, the 64 MiB metadata budget does not bound the
data held by `pngTextChunks`. UTF-8 replacement/Latin-1 conversion can further
make retained string storage larger than the charged source bytes.

**Evidence:** A harmless scanner-only iTXt check with a four-byte budget and
one-byte text retained a 120-byte translated label and a 137-byte raw chunk,
leaving three budget bytes and reporting no skip. This used tiny data and did
not attempt memory exhaustion. The issue is missing accounting for variable
size fields, not the fixed overhead of a Swift object. Scanner checks do not
establish acceptance of every container variation by ImageIO.

**Impact:** Metadata-heavy images can exceed the intended memory ceiling even
when their text bodies fit. The source pixel decode budget does not constrain
these allocations.

**Fix:** Define separate raw-retention and decoded-storage budgets, or a
conservative shared accounting scheme. Check auxiliary-field and raw-body sizes
before string conversion/copy, including damaged compressed chunks. Enforce
valid keyword lengths and account conservatively for string conversion. Report
budget exclusions consistently in the inspector.

**Regression checks:** Use small budgets with ordinary iTXt labels, language
tags, plain and compressed text, and damaged streams. Assert bounds on all
retained fields and raw data, not just `text.utf8.count`.

### S2 — Enforce the PNG work limit before inflating

Locations: [PNGScanner.swift:98](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L98),
[PNGScanner.swift:109](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L109),
[PNGScanner.swift:51](../RescaleKit/Sources/RescaleKit/PNGScanner.swift#L51).

**Owner comment:** Agreed. Add a cumulative decompression allowance per image
(128 MiB, twice the byte budget). Every attempt spends it, including over-limit
and damaged streams. Once it is spent, later compressed chunks are not inflated:
they are skipped and reported in the inspector, damaged ones included.

`deflated` calls `inflated` before `budget.take` checks the remaining element
count. Once `elements` is zero, later compressed chunks still inflate up to the
remaining byte limit, then are discarded. Rejected over-limit chunks also do
not consume the byte budget, allowing that expensive work to recur. The outer
walk continues through all chunks.

**Impact:** The count limit bounds accepted chunks, but not decompression work.
A metadata-heavy file can occupy the sole active decode for a long time; newer
load requests wait behind it. A background task protects the main actor from
the parsing loop but does not make import work bounded or cancellable.

**Evidence boundary:** Confirmed by control flow, not a stress benchmark or
application hang. No resource-exhaustion input was run.

**Fix:** Reject text chunks before decoding when the element allowance is
exhausted. Add a separate cumulative work/decompression allowance that counts
attempts and rejected output. Continue a cheap structural walk if an accurate
skipped count is desired, without decoding omitted fields. Check cancellation
between chunks where feasible.

**Regression checks:** Inject or instrument the inflation routine in tests.
With zero remaining elements, assert zero inflate calls. With several harmless
streams exceeding a deliberately tiny work allowance, assert total attempted
work remains bounded even when none is retained.

### S3 — Apply XMP limits before conversion and fragment collection

Locations: [XMPScanner.swift:36](../RescaleKit/Sources/RescaleKit/XMPScanner.swift#L36),
[XMPScanner.swift:61](../RescaleKit/Sources/RescaleKit/XMPScanner.swift#L61),
[XMPScanner.swift:77](../RescaleKit/Sources/RescaleKit/XMPScanner.swift#L77),
[XMPScanner.swift:165](../RescaleKit/Sources/RescaleKit/XMPScanner.swift#L165).

**Owner comment:** Agreed. Do as HEIF does: TIFF, WebP and the primary JPEG
packet draw on the shared budget, and a packet over it is skipped and reported,
never handed to ImageIO instead. This also closes the TIFF path where a packet
over 64 MiB currently falls back to an unbounded ImageIO parse.

TIFF and WebP dispatch omit the shared budget. TIFF has a separate packet-size
ceiling, but WebP converts the entire XMP chunk to a `String` without even that
ceiling. Being a contiguous slice of the input does not avoid the allocation
and later XMP parsing. JPEG collects extension portions before checking the
budget in `assembled`; neither the collected portion count nor their aggregate
storage is limited at collection time. Its primary packet is also uncharged,
although the JPEG segment format bounds that individual packet.

**Evidence:** A scanner-only WebP container with 17 bytes of ordinary metadata
returned `.found` under a zero-byte, zero-element budget, with no skipped
status. No WebP pixel decode or oversized-file test was performed. JPEG
pre-assembly collection and TIFF's separate limit were verified in source.

**Impact:** The advertised per-image limit varies by format. In particular,
WebP packet conversion and JPEG fragment bookkeeping can exceed it before the
bounded assembly path is reached. Large XMP is subsequently handed to ImageIO
for field extraction.

**Fix:** Pass the budget through every container reader. Charge packet bytes
before string conversion, cap fragment bytes and count before appending, and
bound container bookkeeping. Report a deliberate budget skip without falling
back to an unbounded alternative parsing path. Retain the existing association
and coverage checks for JPEG extended XMP.

**Regression checks:** Apply the same tiny-budget cases across PNG, JPEG, TIFF,
WebP and HEIF. Include primary packets and pre-assembly fragment limits. Require
explicit skipped status and no conversion/assembly beyond the allowance.

### G1 — Associate save completion with the image generation it saved

Locations: [Session.swift:251](../SnapRescale/Sources/SnapRescale/Session.swift#L251),
[Session.swift:275](../SnapRescale/Sources/SnapRescale/Session.swift#L275),
[Session.swift:488](../SnapRescale/Sources/SnapRescale/Session.swift#L488),
[ContentView.swift:22](../SnapRescale/Sources/SnapRescale/ContentView.swift#L22),
[SnapRescaleApp.swift:30](../SnapRescale/Sources/SnapRescale/SnapRescaleApp.swift#L30).

**Owner comment:** Agreed, with the small fix now: a save records its image
generation, and only updates the session status or quits (rechecked after the
delay) while that image is still the current one. The file write, reveal and
error report stay unconditional. One session per window is the planned
structural answer (ROADMAP, "Also next — multiple windows") and comes later; a
drop on a window that already has an image still replaces it, so this check is
needed there too.

The save correctly captures its source and render specification before awaiting
encoding. However, Open, file drops and external opens can request another
image during that await. `load` does not gate on `isSaving`. Completion then
unconditionally writes `lastSaved` into the shared session and, in one-shot
mode, terminates the app. It does not check `loadGeneration`, including after
the final 300 ms suspension.

**Impact:** Saving image A while opening image B can leave B displaying A's
save status. In one-shot mode A's completion can close B before B is saved,
losing the newer session's edits. The saved bytes still belong to captured
image A; this is a lifecycle/status bug, not evidence that B's bytes overwrite
A's export.

**Evidence boundary:** The interleaving follows directly from the actor
suspension and reachable Open/drop paths. It was not reproduced through the
UI. The existing generation guard protects decode completion, not save
completion.

**Fix:** Capture a session generation for saves and publish session-specific
status or auto-quit only if it remains current. Recheck after the quit delay.
Alternatively, explicitly queue imports until the save and one-shot lifecycle
have finished. Preserve the successful file write even when session status has
moved on.

**Regression checks:** Use a controllable encoder to pause A's save, request B,
then complete A. Verify B remains active, does not inherit A's `lastSaved`, and
is not terminated. Cover a replacement request during the quit delay too.

### G2 — Make automatically named output creation exclusive

Locations: [Renderer.swift:186](../RescaleKit/Sources/RescaleKit/Renderer.swift#L186),
[Session.swift:467](../SnapRescale/Sources/SnapRescale/Session.swift#L467),
[SafeWrite.swift:39](../RescaleKit/Sources/RescaleKit/SafeWrite.swift#L39),
[main.swift:138](../RescaleKit/Sources/rescale/main.swift#L138).

**Owner comment:** Agreed for the paths nobody confirms: the silent save next to
the original and the CLI. Save As keeps replacing after the native overwrite
confirmation (decided 2026-09-05). The commit is create-only and moves to the
next counter when the name was taken meanwhile. On a volume that cannot refuse
a replace, fall back to today's check-then-write rather than fail. The CLI gets
the same staged, create-only write.

`OutputNaming.url` checks whether a candidate exists but does not reserve it.
The silent app save chooses that name before asynchronous rendering and later
uses `SafeWrite`, which replaces an existing destination. Another process can
create the chosen filename in the intervening time. CLI output has the same
check-then-write boundary and uses a nonexclusive `Data.write`.

**Evidence:** In an isolated temporary directory, the production naming helper
selected a free destination; a second harmless write created it; the production
`SafeWrite` then replaced that content. This deterministically verifies the
primitive sequence, not an end-to-end concurrent application run.

**Impact:** Concurrent exporters can silently overwrite one another despite
the automatic numeric-suffix scheme. Atomic replacement protects against a
partial write, but does not protect a file that appeared after name selection.
Explicitly confirmed replacement in Save As is a different, intended operation.

**Fix:** Separate confirmed replacement from create-new output. Stage the
complete output, commit with an exclusive/no-replace operation, and on a name
collision select another suffix and retry. Apply the same contract to CLI
output. A second `fileExists` check alone leaves the race intact.

**Regression checks:** Coordinate two writers selecting the same base name and
assert both outputs survive under distinct names. Also insert a file between
selection and commit and assert its original bytes remain unchanged.

## Anti-patterns and lower-priority observations

**Owner comment:** Fix the main-actor write with the G1/G2 save-path work, and
the preset errors alongside. The sandbox validation becomes a release gate: a
checklist in `RELEASING.md`, run on the sandboxed release build before upload.

- **P3 — synchronous disk work on the main actor.** `Session.write`,
  `FolderAccess.write` and inspector export call synchronous `SafeWrite` from
  UI-isolated code. Large outputs or slow/removable volumes can freeze the UI
  after encoding finishes. Keep panels, security-scope lifetime and status on
  the main actor, but move staging and commit to a bounded background operation.
  No slow-volume timing was measured.
- **P3 — silent preset filesystem errors.** `PresetStore.load` treats an
  unreadable directory as empty and ignores directory/initial-preset write
  failures; `delete` ignores removal failure. Individual malformed presets are
  now reported, but filesystem failures still look like missing/no-op settings.
  Surface those errors without replacing the last known good in-memory list.
- **Verification gap — sandboxed persistence.** The folder-bookmark and staged
  replacement paths need a signed sandbox test across grant, save, relaunch,
  moved folder, and revoked grant. SwiftPM success does not verify sandbox
  entitlement behavior. This is a validation requirement, not a confirmed
  sandbox vulnerability.

## Validation and limits

| Check | Result |
|---|---|
| `swift test --package-path RescaleKit` | 283 tests in 23 suites passed |
| `swift build --package-path SnapRescale` | Passed |
| Small scanner checks compiled against current kit sources | Confirmed S1 and WebP portion of S3 |
| Isolated naming/staged-write check | Confirmed G2 primitive sequence |
| `zsh -n` on release, App Store and app/Xcode build scripts | Passed |
| `git diff --check` | Passed |

Checks used the ordinary local SwiftPM build directories and disposable files
under `/tmp`; no review test or probe was added to production sources. Existing
SafeWrite tests cover creation, replacement, staging failure and commit failure.
Metadata tests cover aggregate text bodies, chunk retention count, HEIF joined
extents, nested XMP filtering and format round trips, but not all boundaries
listed above.

Current safeguards include checked source-area arithmetic, a source pixel
decode limit, target-size validation, one active/one pending load, coalesced
render estimation, staged app/inspector writes, source-aware metadata capability
reporting, and recursive XMP filtering. Earlier missing aggregate PNG text and
HEIF assembly limits have been addressed; S1–S3 identify remaining gaps in the
new budget coverage rather than claiming those fixes are absent.

Package manifests declare no remote package dependency. Configured app
entitlements enable sandboxing and user-selected file read/write; the reviewed
entitlement file has no network entitlement. The inspected image/workflow paths
treat workflow metadata as data, not executable instructions. No confirmed code
execution, sandbox escape or new privacy-filter bypass was found in this pass;
that is not proof of absence.

This was not a full UI walkthrough, stress/fuzz campaign, signed sandbox test,
release archive/notarization validation, secret-history audit, or audit of
Apple's image/XML decoders. No external publication, deployment or exploit work
was performed. Source-only findings and scanner-only runtime checks are marked
individually above so they are not mistaken for end-to-end application results.

---

## Resolution log (coding assistant, 2026-10-03)

Fixed on `review/fixes-2026-10-03` (milestone "Review 2026-10-03", tracking
#45). Each finding was first checked independently against `8295701`; the
fixes were then made one commit per item, each reviewed by two or three
reviewers with different lenses, and their confirmed findings folded in.

| Finding | Status | Commit · issue |
|---|---|---|
| S2 PNG work limit | **Fixed.** `MetadataBudget.work`, 128 MiB per image; every inflate attempt spends what it produced, at least one 64 KiB buffer; nothing is inflated without an element or work left; skips are reported, damaged streams included | `6f48b39` · #36 |
| S1 PNG retained data | **Fixed.** Raw copy, keyword, language, translated keyword and decoded text are charged before the raw copy is made; text is built as native UTF-8 of exactly the charged size (Latin-1 and lossy repair included); a damaged chunk that does not fit is skipped and reported | `ea43dc1` · #37 |
| S3 XMP in every container | **Fixed.** TIFF, WebP and the primary JPEG packet draw on the budget; over it is skipped and reported, never handed to ImageIO (the TIFF fallback is gone); extended-XMP collection is bounded; an extension dropped for size says so as a loss note | `4e17b78` · #38 |
| G2 exclusive create | **Fixed.** `SafeWrite.create` stages once and commits with `renamex_np(RENAME_EXCL)`, moving to the next counter on a collision; check-then-replace fallback on volumes without it; silent save and CLI use it; Save As and Export still replace | `9a9bfe3` · #39 |
| P3 main-actor write | **Fixed.** `writeDetached` / `createDetached`; a quit waits for writes in flight (`applicationShouldTerminate`) | `2e4f877` · #40 |
| G1 save vs. newer image | **Fixed.** A save keeps its load generation (Save As: before the panel); `lastSaved` and the one-shot quit only while it is current, rechecked after the delay; the quit runs from a run-loop block so a pending export cannot hang it | `051d30e` · #41 |
| Found in verification: folder grants | **Fixed.** A stored grant covers subfolders (path components); only a refusal leads to asking again | `0e93a43` · #42 |
| P3 preset errors | **Fixed.** Folder problems in the Preset menu with the last list kept; a failed Delete reports; no force unwrap after Save Preset; new SwiftPM test target `SnapRescaleTests` | `658951e` · #43 |
| Verification gap: sandbox | **Checklist added** to `docs/RELEASING.md` as a release gate; not yet run | #44 |

**Verified:** `swift test --package-path RescaleKit` 307 tests in 24 suites;
`swift test --package-path SnapRescale` 9 tests; app build without warnings.
In an unsandboxed dev build, against the same scripts on `main`:

| Trial | `main` | fixed |
|---|---|---|
| Open B while A's Save & Quit encodes (×2) | app quits | stays open |
| Open B within 300 ms of A's file landing (×2) | app quits | stays open |
| Another process creates the output name during the render | its bytes overwritten | kept; output `_2` |
| `--save` alone (control) | quits | quits |

`rescale --write` twice gives `_2`. Crafted-file probes by the reviewers
confirmed the bounds: inflate work at most 128 MiB per image, retained text
equal to the charge.

**Not verified:** the sandboxed build (renamex_np under the App Sandbox,
staging, folder grants, relaunch); that is the RELEASING.md checklist. Whether
ImageIO itself reads a large WebP/TIFF XMP during the pixel load is outside
the scanners' budget and was not measured.
