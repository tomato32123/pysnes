"""Which of the emulated features any real software actually switches on.

A test can say a feature behaves correctly.  It cannot say anyone uses it,
and a feature no cartridge has ever exercised is a feature whose correctness
rests entirely on having read the documentation right.  Knowing which ones
those are is the difference between "implemented" and "seen working".

    python tools/featureprobe.py <rom-dir> [--frames 1200]

Reports, per feature, how many titles turned it on and names a few.
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.batchtest import find_roms

# Each probe is a predicate over the machine, sampled once a frame.  They ask
# "was this ever on", not "is it on now", because most are momentary.
PROBES = {
    "bg mode 0": lambda f: f["bg_mode"] == 0,
    "bg mode 1": lambda f: f["bg_mode"] == 1,
    "bg mode 2 (offset-per-tile)": lambda f: f["bg_mode"] == 2,
    "bg mode 3": lambda f: f["bg_mode"] == 3,
    "bg mode 4 (offset-per-tile)": lambda f: f["bg_mode"] == 4,
    "bg mode 5 (hires)": lambda f: f["bg_mode"] == 5,
    "bg mode 6 (hires + OPT)": lambda f: f["bg_mode"] == 6,
    "bg mode 7": lambda f: f["bg_mode"] == 7,
    "bg3 priority": lambda f: f["bg3_priority"],
    "interlace": lambda f: f["interlace"],
    "obj interlace": lambda f: f["obj_interlace"],
    "overscan": lambda f: f["overscan"],
    "pseudo-hires": lambda f: f["pseudo_hires"],
    "extbg": lambda f: f["extbg"],
    "direct colour": lambda f: f["cgwsel"] & 0x01,
    "mosaic": lambda f: f["mosaic_size"] and any(f["mosaic_enable"]),
    "colour math": lambda f: f["cgadsub"] & 0x3F,
    "main screen forced black": lambda f: (f["cgwsel"] >> 6) & 3,
    "subscreen as operand": lambda f: f["cgwsel"] & 0x02,
    "sprite range over": lambda f: f["range_over"],
    "sprite time over": lambda f: f["time_over"],
    "counter latch": lambda f: f["latched"],
}

# Cartridge features, asked of the board rather than the PPU.
BOARD_PROBES = {
    "SA-1 timers": lambda b: getattr(b, "status", lambda: {})().get(
        "timer", {}).get("tmc", 0) & 3,
    "SA-1 char conversion 1": lambda b: getattr(b, "status", lambda: {})().get(
        "counts", {}).get("cc1", 0),
    "SA-1 char conversion 2": lambda b: getattr(b, "status", lambda: {})().get(
        "counts", {}).get("cc2", 0),
    "SA-1 DMA": lambda b: getattr(b, "status", lambda: {})().get(
        "counts", {}).get("dma", 0),
    "SA-1 arithmetic": lambda b: getattr(b, "status", lambda: {})().get(
        "counts", {}).get("math", 0),
    "SA-1 varlen reader": lambda b: getattr(b, "status", lambda: {})().get(
        "counts", {}).get("varlen", 0),
}


def probe_one(path, frames):
    seen = set()
    try:
        machine = System(path)
    except Exception:
        return None, seen
    board = machine.bus.board
    try:
        for _ in range(frames):
            machine.run_frame()
            f = machine.ppu.features()
            for name, fn in PROBES.items():
                if name not in seen and fn(f):
                    seen.add(name)
    except Exception:
        pass
    for name, fn in BOARD_PROBES.items():
        try:
            if fn(board):
                seen.add(name)
        except Exception:
            pass
    return machine, seen


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("romdir")
    ap.add_argument("--frames", type=int, default=1200)
    opts = ap.parse_args()

    users = collections.defaultdict(list)
    roms = find_roms(opts.romdir)
    for i, path in enumerate(roms, 1):
        name = os.path.basename(path)
        _machine, seen = probe_one(path, opts.frames)
        for feature in seen:
            users[feature].append(name)
        print("%3d/%d %s" % (i, len(roms), name[:60]), file=sys.stderr)

    order = list(PROBES) + list(BOARD_PROBES)
    print()
    print("%-32s %5s  %s" % ("feature", "roms", "for example"))
    for feature in order:
        who = users.get(feature, [])
        example = ", ".join(os.path.splitext(n)[0][:26] for n in who[:2])
        print("%-32s %5d  %s" % (feature, len(who), example or "-- nothing --"))
    print()
    unused = [f for f in order if not users.get(f)]
    if unused:
        print("Never switched on by anything in this library, so correctness")
        print("rests on the documentation alone:")
        for f in unused:
            print("  - %s" % f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
