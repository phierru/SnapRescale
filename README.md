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
- [ComfyUI node review](docs/reference/comfyui-node-review.md) — source material

## RescaleKit

`RescaleKit/` is the Swift package the app, CLI and Quick Action will all drive.
M0 (the dimension solver) is in and tested:

```sh
cd RescaleKit && swift test
```

The tests replay a fixture generated from the Python prototype
(`python3 prototype/export_fixture.py > RescaleKit/Tests/RescaleKitTests/Fixtures/solver-parity.json`)
so the port cannot drift from the behaviour tables in the PRD. Requires Xcode 26 / Swift 6.2+.

A throwaway CLI (PRD §14 M1) exercises the solver against real files. It reads
the source dimensions through ImageIO and prints the solve; it does not write
pixels yet:

```sh
cd RescaleKit && swift build
.build/debug/rescale --aspect 16:9 --width 1920 --multiple 16 photo.heic
.build/debug/rescale --mp 1.5 --source 6000x4000
```

## Prototype

`prototype/solver.py` is a working model of the dimension solver — the piece the
whole app hangs off. `python3 prototype/cases.py` and `python3 prototype/compare.py`
print the behaviour tables reproduced in §5 and §6 of the PRD.

## Status

Draft PRD v0.5 (v1 = single image). **M0 done**: solver ported to Swift with
property tests and prototype parity. Next: M1, `RescaleKit` image pipeline
(decode → resize → crop/pad → encode) with a throwaway CLI.
