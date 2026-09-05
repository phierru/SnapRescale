"""Rescale dimension solver — prototype.

Model: the target size has exactly 2 degrees of freedom (width, height).
Everything the user can type -- aspect, megapixels, width, height, long edge,
short edge, scale -- is a *constraint* on those two. The user pins constraints
by editing them; the two most-recently-edited independent ones win, and any
remaining freedom is inherited from the source image.

`multiple` is not a degree of freedom. It is a quantisation applied after the
continuous solve, choosing the nearby lattice point with the least aspect-ratio
deviation.
"""
import math
from dataclasses import dataclass, field

# aspect ratio deviation dominates; pixel-count deviation only breaks ties.
W_ASPECT, W_PIXELS = 1.0, 0.05


@dataclass
class Solution:
    width: int
    height: int
    ideal_w: float
    ideal_h: float
    aspect_error_pct: float
    pixel_error_pct: float
    used: list = field(default_factory=list)


def solve_continuous(pins, src_w, src_h):
    """pins: ordered most-recent-first list of (key, value). Returns (w, h, used)."""
    src_ar, src_px = src_w / src_h, src_w * src_h
    c, used = {}, []
    for key, val in pins:
        if key in c:
            continue
        trial = dict(c)
        trial[key] = val
        if _rank(trial) > _rank(c):          # keep only constraints that add information
            c, _ = trial, used.append(key)
        if _rank(c) == 2:
            break

    # inherit remaining freedom from the source
    if _rank(c) < 2:
        if "aspect" not in c and _rank({**c, "aspect": src_ar}) > _rank(c):
            c["aspect"] = src_ar
    if _rank(c) < 2:
        c["megapixels"] = src_px / 1e6

    return (*_solve(c, src_ar, src_px), used)


def _rank(c):
    """How many degrees of freedom this constraint set removes (0, 1 or 2)."""
    n = len(c)
    return 2 if n >= 2 else n


def _solve(c, src_ar, src_px):
    ar = c.get("aspect")
    if "width" in c and "height" in c:
        return float(c["width"]), float(c["height"])
    if "scale" in c:                                  # linear scale of the source
        c = {**c, "megapixels": src_px * c["scale"] ** 2 / 1e6}
        c.pop("scale")
    if ar is not None:
        if "megapixels" in c:
            px = c["megapixels"] * 1e6
            return math.sqrt(px * ar), math.sqrt(px / ar)
        if "width" in c:
            return float(c["width"]), c["width"] / ar
        if "height" in c:
            return c["height"] * ar, float(c["height"])
        if "long" in c:
            L = c["long"]
            return (float(L), L / ar) if ar >= 1 else (L * ar, float(L))
        if "short" in c:
            S = c["short"]
            return (S * ar, float(S)) if ar >= 1 else (float(S), S / ar)
    if "megapixels" in c:
        px = c["megapixels"] * 1e6
        if "width" in c:
            return float(c["width"]), px / c["width"]
        if "height" in c:
            return px / c["height"], float(c["height"])
    raise ValueError(f"unsolvable constraint set: {c}")


def snap(w, h, multiple, target_ar, span=2):
    """Pick the lattice point near (w, h) with the least aspect deviation."""
    if multiple <= 1:
        return max(1, round(w)), max(1, round(h))
    target_px = w * h
    base_w, base_h = math.floor(w / multiple), math.floor(h / multiple)
    best, best_score = None, float("inf")
    for i in range(-span, span + 2):
        for j in range(-span, span + 2):
            cw, ch = (base_w + i) * multiple, (base_h + j) * multiple
            if cw < multiple or ch < multiple:
                continue
            score = (W_ASPECT * math.log((cw / ch) / target_ar) ** 2
                     + W_PIXELS * math.log((cw * ch) / target_px) ** 2)
            if score < best_score:
                best, best_score = (cw, ch), score
    return best


def solve(pins, src_w, src_h, multiple=1):
    w, h, used = solve_continuous(pins, src_w, src_h)
    target_ar = w / h
    sw, sh = snap(w, h, multiple, target_ar)
    return Solution(sw, sh, w, h,
                    abs((sw / sh) / target_ar - 1) * 100,
                    abs((sw * sh) / (w * h) - 1) * 100, used)

# ---------------------------------------------------------------------------
MULTIPLES = (1, 8, 16)


def anchored_axes(pins, w, h):
    """Which axes did the user pin *numerically*? Those must survive snapping."""
    a = set()
    for key, _ in pins:
        if key == "width":    a.add("w")
        elif key == "height": a.add("h")
        elif key == "long":   a.add("w" if w >= h else "h")
        elif key == "short":  a.add("h" if w >= h else "w")
    return a


def snap_respecting_pins(w, h, multiple, target_ar, anchors, span=3):
    """Anchored axes snap to the nearest lattice value and are then held fixed;
    only free axes are searched."""
    if multiple <= 1:
        return max(1, round(w)), max(1, round(h))
    target_px = w * h

    def lattice(v):
        return max(multiple, round(v / multiple) * multiple)

    def window(v):
        b = math.floor(v / multiple)
        return [(b + i) * multiple for i in range(-span, span + 2)
                if (b + i) * multiple >= multiple]

    ws = [lattice(w)] if "w" in anchors else window(w)
    hs = [lattice(h)] if "h" in anchors else window(h)

    best, best_score = None, float("inf")
    for cw in ws:
        for ch in hs:
            score = (W_ASPECT * math.log((cw / ch) / target_ar) ** 2
                     + W_PIXELS * math.log((cw * ch) / target_px) ** 2)
            if score < best_score:
                best, best_score = (cw, ch), score
    return best


def hold_anchors(w, h, multiple, anchors):
    """Snap the anchored axis to the lattice first, then re-derive the free axis
    from the value the user will actually get. Without this, a typed 1500 at
    16:9 would pick a height that best matches 1500 -- a width the user is not
    getting -- rather than the 1504 that is being written."""
    if multiple <= 1:
        return w, h
    ar = w / h
    if "w" in anchors and "h" not in anchors:
        w2 = max(multiple, round(w / multiple) * multiple)
        return w2, w2 / ar
    if "h" in anchors and "w" not in anchors:
        h2 = max(multiple, round(h / multiple) * multiple)
        return h2 * ar, h2
    return w, h


def solve2(pins, src_w, src_h, multiple=1):
    w, h, used = solve_continuous(pins, src_w, src_h)
    anchors = anchored_axes(pins, w, h)
    w, h = hold_anchors(w, h, multiple, anchors)
    target_ar = w / h
    sw, sh = snap_respecting_pins(w, h, multiple, target_ar, anchors)
    return Solution(sw, sh, w, h,
                    abs((sw / sh) / target_ar - 1) * 100,
                    abs((sw * sh) / (w * h) - 1) * 100, used)
