# SnapRescale

**Resize to any ratio, snapped to multiples of 8 and 16.**

A native macOS image resizer, built because Parallels Toolbox's *Resize
Images* and Apple's *Convert Image* Quick Action both stop one step short of
useful.

The resize model is ported from ComfyUI's stock `Resize Image/Mask` and
`Resolution Selector` nodes, which — improbably — think about the problem more
clearly than any Mac utility on this machine.

Pick an aspect ratio (or keep the original) and one number — width, height or
megapixels. Everything else solves itself.

## Docs

- [PRD](docs/PRD.md) — requirements, scope, milestones
- [Help](docs/HELP.md) — the brief in-app help, as a page
- [Roadmap](docs/ROADMAP.md) — what is deferred, and in what order it comes back
- [ComfyUI node review](docs/reference/comfyui-node-review.md) — source material
- [Image metadata](docs/reference/image-metadata.md) — what the badges detect

## The app

`SnapRescale/` is the SwiftUI app, a thin shell over RescaleKit. Build it into a
runnable bundle (ad-hoc signed, no Xcode project needed) and open an image:

```sh
./Scripts/build-app.sh                       # fast dev build, unsandboxed → build/SnapRescale.app
open build/SnapRescale.app photo.heic        # or launch it and drop an image on the window
open build/SnapRescale.app --args --aspect 16:9 --width 1920 --multiple 16 photo.heic

./Scripts/build-xcode.sh Release             # store-style build: sandboxed, hardened → build/xcode/SnapRescale.app
```

The app icon is a macOS 26 Liquid Glass package, `SnapRescale/AppIcon.icon`
(three vector layers; the system derives light, dark, clear and tinted). Open it
in Icon Composer to tweak. `Scripts/make-icns.sh` rasterises the flat version in
`SnapRescale/IconSource/` for the dev build and the older-OS fallback.

The Xcode project is generated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`); the `.xcodeproj` itself is not committed. Under the
sandbox, files must arrive by Open With, drop, ⌘O or Services — a path in
`--args` is not readable there, which is why the dev build exists.

## RescaleKit

`RescaleKit/` is the Swift package the app, CLI and Quick Action will all drive.
M0 (the dimension solver) is in and tested:

```sh
cd RescaleKit && swift test
```

The tests replay a fixture generated from the Python prototype
(`python3 prototype/export_fixture.py > RescaleKit/Tests/RescaleKitTests/Fixtures/solver-parity.json`)
so the port cannot drift from the behaviour tables in the PRD. Requires Xcode 26 / Swift 6.2+.

A throwaway CLI (PRD §14 M1) exercises the pipeline against real files. Without
`--write` it only reports the solve; with it, it writes next to the original:

```sh
cd RescaleKit && swift build
.build/debug/rescale --aspect 16:9 --width 1920 --multiple 16 photo.heic
.build/debug/rescale --mp 1.5 --source 6000x4000
.build/debug/rescale --aspect 1:1 --width 1024 --format png --write photo.heic
```

## Prototype

`prototype/solver.py` is a working model of the dimension solver — the piece the
whole app hangs off. `python3 prototype/cases.py` and `python3 prototype/compare.py`
print the behaviour tables reproduced in §5 and §6 of the PRD.

## Status

Draft PRD v0.12 (v1 = single image). **M0 done**: solver ported to Swift with
property tests and prototype parity. **First vertical slice of M1 + M3
running**: decode → resize → crop/pad → encode via ImageIO, a `rescale` CLI
that writes files, and a SwiftUI window with drop target, live crop preview,
aspect/size/multiple controls, real output byte count and Save. Opened from Finder (Open With, the *Resize with SnapRescale* Services entry,
or a Dock drop) it is a one-shot tool that quits after saving; launched from
the Applications menu it stays open. Still to do: the §10 keep/strip switches,
WebP (M4), presets and packaging (M5). The M2 slider was dropped.

## Licence

MIT — see [LICENSE](LICENSE). Free on the Mac App Store, source here.

## Acknowledgements

The resize model — one selector for every resize intent, aspect ratio plus
megapixels as a calculator, snapping to a multiple, and crop-or-stretch as the
only honest answers to an aspect mismatch — is taken from the stock
**Resize Image/Mask** and **Resolution Selector** nodes in
[ComfyUI](https://github.com/comfyanonymous/ComfyUI), which is GPL-3.0. No
ComfyUI code is used; SnapRescale re-implements the ideas in Swift, and the
aspect-ratio names in the picker ("Portrait Photo", "Widescreen", …) are
theirs. Thank you.
