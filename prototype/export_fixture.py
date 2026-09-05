"""Export a parity fixture for the Swift port of the solver.

Runs `solve2` (the pin-respecting solver the PRD adopted) over a grid of
sources × aspects × size parameters × multiples and writes the results as JSON.
The Swift test suite replays every case and expects identical integer output.

    python3 prototype/export_fixture.py > RescaleKit/Tests/RescaleKitTests/Fixtures/solver-parity.json
"""
import json
import sys
from solver import solve2

SOURCES = [(6000, 4000), (4000, 6000), (3000, 3000), (1234, 777)]
ASPECTS = [None, (1, 1), (2, 3), (3, 2), (3, 4), (4, 3), (9, 16), (16, 9), (21, 9)]
MULTIPLES = [1, 8, 16]

# Widths and heights deliberately straddle lattice points, half-way points and
# the detent ladder. Megapixel and scale values are the ones the UI offers.
WIDTHS = [128, 129, 135, 136, 137, 200, 500, 512, 520, 640, 768, 1000, 1024,
          1032, 1040, 1280, 1500, 1536, 1600, 1920, 1936, 2048, 2560, 3840, 4000, 6000, 7000]
HEIGHTS = [128, 300, 480, 512, 700, 720, 768, 900, 1024, 1080, 1088, 1440, 2048, 2160, 4000]
MEGAPIXELS = [0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 12.0]
SCALES = [0.1, 0.25, 0.5, 0.75, 1.0, 1.5]


def params():
    for w in WIDTHS:
        yield "width", w
    for h in HEIGHTS:
        yield "height", h
    for mp in MEGAPIXELS:
        yield "megapixels", mp
    for s in SCALES:
        yield "scale", s


cases = []
for src in SOURCES:
    for aspect in ASPECTS:
        for key, value in params():
            pins = [(key, value)]
            if aspect is not None:
                pins.append(("aspect", aspect[0] / aspect[1]))
            for m in MULTIPLES:
                s = solve2(pins, *src, multiple=m)
                cases.append({
                    "source": list(src),
                    "aspect": list(aspect) if aspect else None,
                    "param": key,
                    "value": value,
                    "multiple": m,
                    "ideal": [s.ideal_w, s.ideal_h],
                    "result": [s.width, s.height],
                })

json.dump({"generator": "prototype/export_fixture.py", "cases": cases}, sys.stdout, separators=(",", ":"))
print(file=sys.stderr, *[f"{len(cases)} cases"])
