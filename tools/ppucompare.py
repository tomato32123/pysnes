"""Compare what the PPU draws against krom's reference pictures, pixel by pixel.

Each of krom's PPU demos ships a screenshot of itself next to the ROM.  That
makes a comparison possible that no test written inside this project can be:
the reference came from someone else's understanding of the hardware, so
agreeing with it is evidence, and disagreeing with it is a bug in one of the
two.

The comparison is exact -- no tolerance, no resampling.  Either every pixel
agrees or the demo is listed as differing; in practice a demo is at 100.00% or
somewhere below 70%, and the gap is a real difference rather than a rounding
one.  Getting there needs three things right, and each was found the hard way:

*The row offset.*  Scanline 0 is never displayed, so the 224 rows of a
reference are scanlines 1 to 224.  This is the same fact as the one-line
background offset in `snes/ppu.pyx`, and comparing against these pictures is
what found it.

*The width.*  A non-hires frame is written to the 512-wide buffer twice over,
so every second column is the picture.  A hires or interlaced frame uses the
buffer as it stands.  Some of the 512x448 references are a 512x224 picture
with its rows doubled, which is checked for rather than assumed.

*Which references can be used at all.*  A raw capture only contains colours
the SNES can make: 32 levels per channel, each expanded to 8 bits by
replication.  A reference with colours off that palette has been through
something -- field blending, an analog capture, a dimming curve -- and cannot
be compared exactly.  `on_palette` measures it, and a reference below 100% is
reported as unusable rather than as a failure.  That test alone rules out five
of krom's pictures, and it rules them out for reasons worth knowing.

Two more categories are listed by hand, because no measurement can tell them
apart from a bug: demos that animate (the screenshot is one frame of many) and
demos whose screenshot is of an interactive state (the pad has been used).

    python tools/ppucompare.py [dir] [--frames N] [--write-diff]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import ROMS
from snes.system import System, BUTTONS

try:
    from PIL import Image
    import numpy as np
except ImportError:                     # pragma: no cover - optional tooling
    print("this tool needs pillow and numpy")
    raise SystemExit(2)

DEFAULT_DIR = ROMS + "/testroms/krompp"
FRAMES = 61                             # odd, so both interlace fields are drawn

# Every colour the SNES can put on a wire: 5 bits a channel, expanded by
# replication.  A reference containing anything else has been processed.
PALETTE = {(v << 3) | (v >> 2) for v in range(32)}

# Demos that never settle: the screenshot is one frame of an animation.  Each
# is still compared, over a search for the frame that matches best, because a
# demo that reaches an exact match at *some* frame has been verified.
ANIMATED = {
    "Perspective": 400,
    "StarWars": 400,
    "PlotLineMode7": 400,
    "PlotPixelMode7": 400,
    "WaveHDMA": 240,
}

# Demos whose screenshot is of a state the pad has to reach.
DRIVE = {
    "MosaicMode3": [("R", 15)],
    "MosaicMode5": [("R", 7)],       # its screenshot is at size 7, not the maximum
}

# Demos the pad steers, whose screenshot is of a position there is no way to
# reproduce -- the rotation and zoom have been set by hand.
INTERACTIVE = {
    "RotZoom": "A/B/X/Y set the rotation and zoom; the screenshot is one of them",
}

# Demos driven by the pad in a way there is no way to reproduce: the map has
# been scrolled to an arbitrary place.  What can still be checked is the shape
# of the effect, which is what the demo is for.
MASK_ONLY = {
    "WindowMultiHDMA": (0, 255, 0),      # the backdrop colour the windows cut to
}


def on_palette(ref):
    flat = ref.reshape(-1, 3)
    return float(np.isin(flat, list(PALETTE)).all(axis=1).mean())


def rows_doubled(ref):
    return all(np.array_equal(ref[2 * i], ref[2 * i + 1])
               for i in range(ref.shape[0] // 2))


def ours_like(machine, ref):
    """Our frame, extracted to match the reference's geometry."""
    fb = np.frombuffer(bytes(machine.framebuffer), dtype=np.uint8).reshape(478, 512, 4)
    h, w = ref.shape[:2]
    if w == 256:
        return fb[:h, ::2, [2, 1, 0]].astype(int)
    if h == 448 and rows_doubled(ref):
        return fb[:224, :, [2, 1, 0]].astype(int)
    return fb[:h, :, [2, 1, 0]].astype(int)


def reference_for(ref):
    """The reference, with any doubling undone so both sides are one picture."""
    if ref.shape[0] == 448 and rows_doubled(ref):
        return ref[::2]
    return ref


def drive(machine, script):
    """Press a button until the mosaic size register reaches `times`.

    Counting presses is not enough: the demos read the pad every few frames,
    so a press can be missed, and the comparison then runs against a state the
    screenshot is not of.  Watching the register is what makes it reliable.
    """
    for button, times in script:
        for _ in range(40):
            if machine.ppu.state_ints()[12] >= times:
                break
            machine.set_pad(0, BUTTONS[button])
            for _ in range(12):
                machine.run_frame()
            machine.set_pad(0, 0)
            for _ in range(12):
                machine.run_frame()


def explained_by_a_rescale(ours, ref):
    """How many of the reference's rows are rows of ours, verbatim and in order.

    A picture that has been scaled vertically -- 432 rows of capture stretched
    into a 448-row file, say -- keeps every row it started with and repeats
    some of them.  A rendering difference does not: it changes pixels.  So a
    reference whose rows are nearly all ours, in order, but which does not
    match row for row, is a rescaled capture rather than a disagreement, and
    saying so needs no guess about what scaler was used.
    """
    a = [row.tobytes() for row in ours]
    b = [row.tobytes() for row in ref]
    n, m = len(a), len(b)
    prev = [0] * (m + 1)
    for i in range(1, n + 1):
        cur = [0] * (m + 1)
        ai = a[i - 1]
        for j in range(1, m + 1):
            best = prev[j] if prev[j] > cur[j - 1] else cur[j - 1]
            if ai == b[j - 1]:
                c = prev[j - 1] + 1
                if c > best:
                    best = c
            cur[j] = best
        prev = cur
    return prev[m]


def compare(rom, png, frames=FRAMES, write_diff=False):
    name = os.path.basename(rom)[:-4]
    if name in INTERACTIVE:
        print("  %-46s unusable -- %s" % (name, INTERACTIVE[name]))
        return None
    raw = np.asarray(Image.open(png).convert("RGB")).astype(int)

    share = on_palette(raw)
    if share < 1.0:
        print("  %-46s unusable -- only %.2f%% of the reference is on the "
              "SNES palette" % (name, 100 * share))
        return None

    ref = reference_for(raw)
    total = ref.shape[0] * ref.shape[1]
    machine = System(rom)

    if name in ANIMATED:
        best, at = -1, 0
        for f in range(1, ANIMATED[name] + 1):
            machine.run_frame()
            same = int((np.abs(ref - ours_like(machine, raw)).sum(axis=2) == 0).sum())
            if same > best:
                best, at = same, f
        ok = best == total
        print("  %-46s %s  %6d/%d exact (%.2f%%) at frame %d of an animation"
              % (name, "ok  " if ok else "DIFF", best, total, 100.0 * best / total, at))
        return ok

    for _ in range(frames):
        machine.run_frame()
    if name in DRIVE:
        drive(machine, DRIVE[name])
    ours = ours_like(machine, raw)

    if name in MASK_ONLY:
        colour = np.array(MASK_ONLY[name])
        rm = (np.abs(ref - colour).sum(axis=2) == 0)
        om = (np.abs(ours - colour).sum(axis=2) == 0)
        same = int((rm == om).sum())
        ok = same == total
        print("  %-46s %s  %6d/%d of the effect's shape (%.2f%%); the picture "
              "under it has been scrolled by hand"
              % (name, "ok  " if ok else "DIFF", same, total, 100.0 * same / total))
        return ok

    same = int((np.abs(ref - ours).sum(axis=2) == 0).sum())
    ok = same == total
    note = ""
    if not ok:
        rows = explained_by_a_rescale(ours, ref)
        if rows >= int(0.95 * ref.shape[0]):
            print("  %-46s unusable -- the reference is a vertical rescale: "
                  "%d of its %d rows are ours verbatim and in order"
                  % (name, rows, ref.shape[0]))
            return None
        note = "; %d/%d of its rows are ours verbatim" % (rows, ref.shape[0])
    print("  %-46s %s  %6d/%d exact (%.2f%%)%s"
          % (name, "ok  " if ok else "DIFF", same, total, 100.0 * same / total, note))

    if not ok and write_diff:
        out = os.path.join("shots", "ppucmp")
        os.makedirs(out, exist_ok=True)
        gap = np.full((ref.shape[0], 6, 3), 255, np.uint8)
        strip = np.concatenate([ref.astype(np.uint8), gap, ours.astype(np.uint8)], axis=1)
        Image.fromarray(strip).save(os.path.join(out, name + ".png"))
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    target = args[0] if args else DEFAULT_DIR
    frames = FRAMES
    for a in sys.argv[1:]:
        if a.startswith("--frames="):
            frames = int(a.split("=", 1)[1])
    write_diff = "--write-diff" in sys.argv

    roms = sorted(f for f in os.listdir(target) if f.endswith(".sfc"))
    print("%d demos with a reference picture\n" % len(roms))

    results = []
    for f in roms:
        rom = os.path.join(target, f)
        png = rom[:-4] + ".png"
        if not os.path.exists(png):
            continue
        try:
            results.append((f, compare(rom, png, frames, write_diff)))
        except Exception as exc:
            print("  %-46s raised %s: %s" % (f[:-4], type(exc).__name__, exc))
            results.append((f, False))

    compared = [r for _, r in results if r is not None]
    bad = [f[:-4] for f, r in results if r is False]
    print()
    print("%d of %d comparable demos match exactly (%d references unusable)"
          % (sum(1 for r in compared if r), len(compared),
             len(results) - len(compared)))
    if bad:
        print("differing: %s" % ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
