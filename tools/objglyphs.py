"""Read back which OBJ tiles the PPU actually fetched, and check them.

neser's OBJ test ROMs are drawn with undisbeliever's `hex8` glyphs: every
8x8 tile in VRAM is a picture of its own tile number.  So the screen names
the tiles that were fetched, and a capture can be turned back into tile
numbers without a reference image -- match each 8x8 block of the picture
against the tile bitmaps sitting in VRAM.

That is worth doing rather than comparing screenshots, because the answer
it gives is one a person can argue with.  "The V-flipped sprite fetched
30/31 above 20/21" is a claim about the hardware that neser's README
states outright and that ares, higan and Snes9x agree on; "the screen
hashes to a1b2c3" is a claim about nothing.

A block is matched against the tile as stored and against its three
mirrors, because a flipped sprite draws flipped glyphs -- and the mirror
that matched is itself information, so it is reported.

    python tools/objglyphs.py [rom-or-dir]

With no argument it checks every expectation listed in EXPECTED below,
each transcribed from neser's README.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

DEFAULT_DIR = "/home/moto/Projects/rom/testroms/higan/neser-obj-tests"
FRAMES = 30

# Transcribed from neser-obj-tests/README.md.  Each entry is
# (x, y, [rows of tile numbers]) -- what must be on screen at that corner.
EXPECTED = {
    "obj-y-wrap": [
        # The wrapped, unflipped sprite: its lower half is what shows.
        (128, 0, [[0x20, 0x21], [0x30, 0x31]]),
        # The wrapped, V-flipped one.  This is the whole point of the ROM:
        # a 16x32 mirrors within each 16x16 square, so the lower half
        # turns over in place instead of swapping with the upper half.
        (192, 0, [[0x30, 0x31], [0x20, 0x21]]),
        # The fully visible control, unflipped, all four rows.
        (64, 64, [[0x00, 0x01], [0x10, 0x11], [0x20, 0x21], [0x30, 0x31]]),
    ],
}


# The OBSEL size table, quoted from the SNESdev wiki's PPU registers page
# (snes.nesdev.org/wiki/PPU_registers, OBSEL $2101).  Selects 6 and 7 are
# the ones the official development manual never documented.
SIZES = {
    0: ((8, 8), (16, 16)),
    1: ((8, 8), (32, 32)),
    2: ((8, 8), (64, 64)),
    3: ((16, 16), (32, 32)),
    4: ((16, 16), (64, 64)),
    5: ((32, 32), (64, 64)),
    6: ((16, 32), (32, 64)),
    7: ((16, 32), (32, 32)),
}

# Where _obj-size-grid.inc puts its two sprites, and the tile each starts
# from.  A sprite reads a rectangle out of the 16-wide grid of OBJ tiles,
# so an w x h sprite based at tile 0 must show r * 16 + c.
GRID_SPRITES = ((32, 64, "small"), (128, 64, "large"))


def tile_masks(vram, base):
    """{ink pattern: (tile, how it was mirrored)} for every non-blank tile.

    Only which pixels are opaque matters: colour 0 is transparent in an
    object, so the glyph's shape is what reaches the screen.
    """
    out = {}
    for n in range(512):
        off = (base + n * 32) & 0xFFFF
        rows = []
        for r in range(8):
            bits = (vram[(off + r * 2) & 0xFFFF] | vram[(off + r * 2 + 1) & 0xFFFF]
                    | vram[(off + 16 + r * 2) & 0xFFFF]
                    | vram[(off + 17 + r * 2) & 0xFFFF])
            rows.append(tuple(bool((bits >> (7 - c)) & 1) for c in range(8)))
        rows = tuple(rows)
        if not any(any(r) for r in rows):
            continue
        h = tuple(tuple(reversed(r)) for r in rows)
        for pattern, how in ((rows, ""), (h, "H"),
                             (rows[::-1], "V"), (h[::-1], "HV")):
            out.setdefault(pattern, (n, how))
    return out


def obj_base_bytes(machine):
    """Where OBJ tile $000 starts, in bytes.  OBSEL holds a word address."""
    line = [l for l in machine.ppu.dump().splitlines() if l.startswith("OBSEL")][0]
    return int(re.search(r"base=\$([0-9A-Fa-f]+)", line).group(1), 16) * 2


def screen(machine):
    """A dot lookup over the framebuffer.

    The buffer is two columns per dot so that hires modes have somewhere
    to put their left half-dot; the right column is the main screen in
    every mode, which is the one these ROMs draw on.
    """
    fb = memoryview(machine.framebuffer)

    def at(x, y):
        i = (y * 512 + x * 2 + 1) * 4
        return (fb[i + 2], fb[i + 1], fb[i])
    return at


def read_tiles(machine, x, y, cols, rows):
    """Identify the cols x rows block of glyphs whose corner is at (x, y)."""
    vram = bytes(machine.ppu.vram_bytes)
    masks = tile_masks(vram, obj_base_bytes(machine))
    at = screen(machine)
    back = at(4, 4)
    out = []
    for r in range(rows):
        line = []
        for c in range(cols):
            block = tuple(tuple(at(x + c * 8 + i, y + r * 8 + j) != back
                                for i in range(8)) for j in range(8))
            if not any(any(b) for b in block):
                line.append(None)
            else:
                line.append(masks.get(block))
            # An unmatched non-blank block stays None-with-a-marker below.
            if line[-1] is None and any(any(b) for b in block):
                line[-1] = ("?", "")
        out.append(line)
    return out


def show(cell):
    if cell is None:
        return " --"
    n, how = cell
    return "%3s" % ("??" if n == "?" else "%02X%s" % (n, how))


def check_size_grid(path, name, sel):
    """Every size select, read off the screen a tile at a time.

    The sprite's size decides which rectangle of the tile grid it fetches,
    so the glyphs spell out the size the PPU used -- and one row past the
    bottom edge has to be empty, or the sprite was taller than it should
    be.
    """
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()

    bad = 0
    for (x, y, which), (w, h) in zip(GRID_SPRITES, SIZES[sel]):
        cols, rows = w // 8, h // 8
        want = [[r * 16 + c for c in range(cols)] for r in range(rows)]
        got = read_tiles(machine, x, y, cols, rows)
        flat_got = [None if c is None else c[0] for row in got for c in row]
        flat_want = [t for row in want for t in row]
        below = read_tiles(machine, x, y + h, cols, 1)[0]
        right = [row[0] for row in read_tiles(machine, x + w, y, 1, rows)]
        if flat_got == flat_want and not any(below) and not any(right):
            print("  %-18s %-5s %2dx%-2d ok" % (name, which, w, h))
            continue
        bad += 1
        print("  %-18s %-5s %2dx%-2d WRONG" % (name, which, w, h))
        print("      want %s" % " ".join("%3X" % t for t in flat_want))
        print("      got  %s" % " ".join(show(c) for row in got for c in row))
        if any(below):
            print("      and it drew past the bottom edge: %s"
                  % " ".join(show(c) for c in below))
        if any(right):
            print("      and it drew past the right edge: %s"
                  % " ".join(show(c) for c in right))
    return bad


def check(path, name):
    if name.startswith("obj-size-grid-"):
        return check_size_grid(path, name, int(name[-1]))

    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()

    wants = EXPECTED.get(name)
    if not wants:
        print("  %s: nothing published to check against" % name)
        return 0

    bad = 0
    for x, y, want in wants:
        got = read_tiles(machine, x, y, len(want[0]), len(want))
        flat_got = [None if c is None else c[0] for row in got for c in row]
        flat_want = [t for row in want for t in row]
        if flat_got == flat_want:
            print("  %-14s (%3d,%3d) ok    %s" % (
                name, x, y, " ".join(show(c) for row in got for c in row)))
        else:
            bad += 1
            print("  %-14s (%3d,%3d) WRONG" % (name, x, y))
            print("      want %s" % " ".join("%3X" % t for t in flat_want))
            print("      got  %s" % " ".join(show(c) for row in got for c in row))
    return bad


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    if os.path.isdir(target):
        names = sorted(EXPECTED) + ["obj-size-grid-%d" % i for i in range(8)]
        roms = [(os.path.join(target, n + ".sfc"), n) for n in names]
    else:
        roms = [(target, os.path.splitext(os.path.basename(target))[0])]

    bad = 0
    for path, name in roms:
        if not os.path.exists(path):
            print("  %s is not here" % path)
            bad += 1
            continue
        bad += check(path, name)

    print()
    print("the tiles fetched are the ones the hardware fetches" if not bad
          else "%d placement(s) disagree" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
