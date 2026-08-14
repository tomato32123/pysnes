"""Run blargg's SNES test ROMs and read the verdict off the screen.

These are the oldest and strictest tests here -- ADC and SBC in every mode,
the multiplier and divider's behaviour *and* their timing, DMA, HDMA, IRQ and
NMI timing, VRAM access windows -- and they are self-checking: each prints
its own name and then `Passed` or a failure.

Reading that is harder than it sounds.  Unlike krom's ROMs, these do not load
a font whose tile number is the character code; they build glyph bitmaps in
VRAM and draw text as pixels, so there is nothing in the tile map to read.
What is stable is the picture: the same font, the same colour, the same word.
So the word `Passed` is stored here as the pixels it makes, lifted from a run
that was checked by eye, and a test passes when that pattern appears anywhere
on its screen.

A ROM whose screen does not contain it is *not* called a failure.  It is
reported as needing a look, with a screenshot written out, because several of
these ROMs report by other means -- a number, a bar, a colour -- and calling
those failures would be as wrong as calling them passes.

    python tools/blarggtests.py [dir] [--frames N] [--shots dir]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import ROMS
from snes.system import System
from tools.screenshot import write_png

try:
    import numpy as np
except ImportError:                     # pragma: no cover - optional tooling
    print("this tool needs numpy")
    raise SystemExit(2)

DEFAULT_DIR = ROMS + "/testroms/higan/jonasquinn-test-roms"
FRAMES = 1400                           # "Takes 15 seconds" is common; this is 23
SETTLE = 300                            # frames of an unchanging screen to stop early
# ...but not before this, because most of these ROMs print "Takes 15 seconds"
# and then sit perfectly still for those fifteen seconds.  Stopping when the
# screen stops changing catches them mid-wait and reads the wrong verdict.
MIN_FRAMES = 1000

# `Passed`, as blargg's font draws it into the framebuffer: seven rows of the
# 512-wide buffer, in which every pixel is doubled horizontally.
PASSED = [
    "############............................................................................####",
    "####......####..........................................................................####",
    "####......####....########........########........########........########........##########",
    "############............####....####............####............####....####....####....####",
    "####..............##########......########........########......############....####....####",
    "####............####....####............####............####....####............####....####",
    "####..............######..####..##########......##########........########........##########",
]


def template():
    return np.array([[c == "#" for c in row] for row in PASSED])


def screen_mask(machine):
    fb = np.frombuffer(bytes(machine.framebuffer), dtype=np.uint8).reshape(478, 512, 4)
    return fb[:, :, :3].sum(axis=2) > 0


def contains(mask, tmpl):
    """Is the template anywhere in the mask, exactly?"""
    th, tw = tmpl.shape
    lit = int(tmpl.sum())
    # Only the rows and columns where something is drawn are worth testing.
    rows = np.nonzero(mask.sum(axis=1))[0]
    cols = np.nonzero(mask.sum(axis=0))[0]
    if len(rows) == 0:
        return False
    for y in range(max(0, rows.min() - 1), min(478 - th, rows.max()) + 1):
        band = mask[y:y + th]
        for x in range(max(0, cols.min() - 1), min(512 - tw, cols.max()) + 1):
            window = band[:, x:x + tw]
            if int(window.sum()) == lit and np.array_equal(window, tmpl):
                return True
    return False


def run(path, frames):
    machine = System(path)
    last, still = None, 0
    for i in range(frames):
        machine.run_frame()
        if (i + 1) % 60 == 0:
            mask = screen_mask(machine)
            key = (int(mask.sum()), hash(mask.tobytes()))
            if key == last:
                still += 60
                if still >= SETTLE and key[0] > 0 and i >= MIN_FRAMES:
                    break
            else:
                still = 0
                last = key
    return machine


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    target = args[0] if args else DEFAULT_DIR
    frames = FRAMES
    shots = None
    for a in sys.argv[1:]:
        if a.startswith("--frames="):
            frames = int(a.split("=", 1)[1])
        if a.startswith("--shots="):
            shots = a.split("=", 1)[1]

    roms = []
    for dirpath, _dirs, files in os.walk(target):
        for name in sorted(files):
            if name.lower().endswith((".smc", ".sfc")):
                roms.append(os.path.join(dirpath, name))
    roms.sort()
    print("%d ROMs\n" % len(roms))

    tmpl = template()
    passed, unknown, broken = [], [], []
    for path in roms:
        rel = os.path.relpath(path, target)
        try:
            machine = run(path, frames)
        except Exception as exc:
            print("  %-54s raised %s" % (rel[:54], type(exc).__name__))
            broken.append(rel)
            continue
        ok = contains(screen_mask(machine), tmpl)
        print("  %-54s %s" % (rel[:54], "Passed" if ok else "-- look at it"))
        (passed if ok else unknown).append(rel)
        if not ok and shots:
            os.makedirs(shots, exist_ok=True)
            safe = rel.replace("/", "_").rsplit(".", 1)[0]
            write_png(os.path.join(shots, safe + ".png"), machine.framebuffer)

    print()
    print("%d printed Passed, %d report some other way, %d would not run"
          % (len(passed), len(unknown), len(broken)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
