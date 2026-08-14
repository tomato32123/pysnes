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
from tools.romarg import ROMS
from snes.system import System

DEFAULT_DIR = ROMS + "/testroms/higan/neser-obj-tests"
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
    # Four 32x32 sprites, from oam-x8.asm: a control, one clipped by the
    # right edge, one at X = -16 through the high table's X bit 8, and one
    # at X = 256 which must not appear at all.  None means "nothing here".
    "oam-x8": [
        (32, 64, [[r * 16 + c for c in range(4)] for r in range(4)]),
        # X = 240: only the left two tile columns are on screen.
        (240, 64, [[r * 16 + c for c in range(2)] for r in range(4)]),
        # X = -16: the left half is clipped, so the right two columns show
        # at the very left edge of the screen.
        (0, 128, [[r * 16 + c for c in (2, 3)] for r in range(4)]),
        # X = 256: fully off-screen, and the sprite at -16 has already
        # ended by x = 16, so this whole strip has to be empty.
        (16, 128, [[None] * 8 for _ in range(4)]),
    ],
}

# Overlapping sprites cannot be checked a tile at a time: two sprites drawn
# from the same glyphs interleave their opaque pixels, so a block belongs to
# neither of them.  These are checked pixel by pixel instead, by
# check_priority below.  The number is where priority evaluation starts:
# normally sprite 0, but OAMADDH bit 7 moves it, and first-sprite-rotation
# sets it to sprite 2 -- so there the pair 1 and 2 comes out the other way
# round while the control pair 10 and 11 does not.  Both numbers are from
# the ROMs' own sources.
PIXELWISE = {"obj-priority": 0, "first-sprite-rotation": 2}


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


def palette_colours(machine):
    """{rgb: palette} over the eight object palettes, CGRAM 128 upwards.

    Sprites drawn from the same tiles can only be told apart by colour, so
    a block's ink says which sprite won.  Colour 0 of each palette is
    transparent and never reaches the screen, so it is not in here.
    """
    cgram = machine.ppu.cgram_list
    out = {}
    for i in range(128, 256):
        if i % 16 == 0:
            continue
        word = cgram[i]
        rgb = tuple(((word >> s) & 31) << 3 | ((word >> s) & 31) >> 2
                    for s in (0, 5, 10))
        out.setdefault(rgb, (i - 128) // 16)
    return out


def read_tiles(machine, x, y, cols, rows):
    """Identify the cols x rows block of glyphs whose corner is at (x, y).

    A cell is (tile, mirror, palette), or None where nothing was drawn.
    """
    vram = bytes(machine.ppu.vram_bytes)
    masks = tile_masks(vram, obj_base_bytes(machine))
    colours = palette_colours(machine)
    at = screen(machine)
    back = at(4, 4)
    out = []
    for r in range(rows):
        line = []
        for c in range(cols):
            ink = None
            block = []
            for j in range(8):
                row = []
                for i in range(8):
                    rgb = at(x + c * 8 + i, y + r * 8 + j)
                    row.append(rgb != back)
                    if rgb != back and ink is None:
                        ink = rgb
                block.append(tuple(row))
            block = tuple(block)
            if ink is None:
                line.append(None)
                continue
            found = masks.get(block)
            tile, how = found if found else ("?", "")
            line.append((tile, how, colours.get(ink, "?")))
        out.append(line)
    return out


def show(cell):
    if cell is None:
        return "  --"
    tile, how, pal = cell
    return "%4s" % (("??" if tile == "?" else "%02X" % tile) + how + str(pal))


def matches(got, want):
    """Does a cell match what was asked for?

    A wanted cell is a tile number, or (tile, palette) where the palette
    is what says which of two overlapping sprites won, or None for
    nothing drawn.
    """
    if want is None:
        return got is None
    if got is None:
        return False
    if isinstance(want, tuple):
        return (got[0], got[2]) == want
    return got[0] == want


def showwant(want):
    if want is None:
        return "  --"
    if isinstance(want, tuple):
        return "%4s" % ("%02X.%d" % want)
    return "%4X" % want


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
        flat_got = [c for row in got for c in row]
        flat_want = [t for row in want for t in row]
        below = read_tiles(machine, x, y + h, cols, 1)[0]
        right = [row[0] for row in read_tiles(machine, x + w, y, 1, rows)]
        if (all(matches(g, t) for g, t in zip(flat_got, flat_want))
                and not any(below) and not any(right)):
            print("  %-18s %-5s %2dx%-2d ok" % (name, which, w, h))
            continue
        bad += 1
        print("  %-18s %-5s %2dx%-2d WRONG" % (name, which, w, h))
        print("      want %s" % " ".join(showwant(t) for t in flat_want))
        print("      got  %s" % " ".join(show(c) for row in got for c in row))
        if any(below):
            print("      and it drew past the bottom edge: %s"
                  % " ".join(show(c) for c in below))
        if any(right):
            print("      and it drew past the right edge: %s"
                  % " ".join(show(c) for c in right))
    return bad


def sprites(machine):
    """Every sprite OAM describes, as (index, x, y, tile, palette, w, h).

    Read out of OAM rather than out of the ROM's source, so this says what
    the console was told, not what someone meant to say.
    """
    oam = machine.ppu.oam_bytes
    line = [l for l in machine.ppu.dump().splitlines() if l.startswith("OBSEL")][0]
    sel = int(re.search(r"size=(\d)", line).group(1))
    out = []
    for s in range(128):
        hi = oam[512 + (s >> 2)]
        big = (hi >> (((s & 3) << 1) + 1)) & 1
        w, h = SIZES[sel][big]
        x = oam[s * 4]
        if (hi >> ((s & 3) << 1)) & 1:
            x -= 256
        out.append((s, x, oam[s * 4 + 1], oam[s * 4 + 2],
                    (oam[s * 4 + 3] >> 1) & 7, w, h))
    return out


def obj_pixel(vram, base, tile, palette, w, px, py):
    """The CGRAM index a sprite puts at its own (px, py), or 0 for clear."""
    n = (tile + (py >> 3) * 16 + (px >> 3)) & 0x1FF
    off = (base + n * 32 + (py & 7) * 2) & 0xFFFF
    bit = 7 - (px & 7)
    colour = ((vram[off] >> bit) & 1) | (((vram[off + 1] >> bit) & 1) << 1) \
        | (((vram[(off + 16) & 0xFFFF] >> bit) & 1) << 2) \
        | (((vram[(off + 17) & 0xFFFF] >> bit) & 1) << 3)
    return 0 if not colour else 128 + palette * 16 + colour


def check_priority(path, name, first=0):
    """Where two sprites are both opaque, the earlier one in the scan wins.

    That is the lower OAM index, unless OAMADDH bit 7 has moved where the
    scan starts, in which case it is the lower distance forwards from
    there -- which is the whole of what priority rotation does.

    That is the whole claim of obj-priority.sfc, and it holds even when the
    sprite behind asks for a higher OAM priority: those two bits choose
    where the object layer sits against the backgrounds, not which object
    is in front of which.

    Nothing here is hardcoded from the ROM's source.  The sprites come out
    of OAM, the pixels come out of VRAM, and the colour each sprite would
    put at a pixel is worked out and compared against the screen -- so a
    colour that two palettes happen to share cannot make a wrong answer
    look right.
    """
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()
    vram = bytes(machine.ppu.vram_bytes)
    base = obj_base_bytes(machine)
    cgram = machine.ppu.cgram_list
    at = screen(machine)

    def rgb(index):
        word = cgram[index]
        return tuple(((word >> s) & 31) << 3 | ((word >> s) & 31) >> 2
                     for s in (0, 5, 10))

    # A sprite's first scanline is the one after its OAM Y, and the screen
    # row shown at scanline n is row n - 1, so a sprite's top screen row is
    # exactly the Y in OAM.  Sprites that would wrap past the bottom are
    # left out; obj-y-wrap covers those.
    live = [s for s in sprites(machine)
            if -64 < s[1] < 256 and s[2] + s[6] <= 224]
    bad = pairs = 0
    for a in range(len(live)):
        for b in range(a + 1, len(live)):
            ia, ax, ay, at_, apal, aw, ah = live[a]
            ib, bx, by, bt, bpal, bw, bh = live[b]
            if ((ib - first) & 0x7F) < ((ia - first) & 0x7F):
                ia, ax, ay, at_, apal, aw, ah, ib, bx, by, bt, bpal, bw, bh = (
                    ib, bx, by, bt, bpal, bw, bh, ia, ax, ay, at_, apal, aw, ah)
            hits = wrong = 0
            for y in range(max(ay, by), min(ay + ah, by + bh)):
                for x in range(max(ax, bx), min(ax + aw, bx + bw)):
                    if not 0 <= x < 256:
                        continue
                    front = obj_pixel(vram, base, at_, apal, aw,
                                      x - ax, y - ay)
                    behind = obj_pixel(vram, base, bt, bpal, bw,
                                       x - bx, y - by)
                    if not front or not behind:
                        continue
                    hits += 1
                    if at(x, y) != rgb(front):
                        wrong += 1
            if not hits:
                continue
            pairs += 1
            if wrong:
                bad += 1
                print("  %-14s sprite %d is behind sprite %d at %d of %d "
                      "shared pixels" % (name, ia, ib, wrong, hits))
            else:
                print("  %-14s sprite %d covers sprite %d, %d shared pixels"
                      % (name, ia, ib, hits))
    if not pairs:
        print("  %-14s no sprites overlap: nothing was checked" % name)
        return 1
    return bad


# obj-bg-priority.asm draws a BG1 band of tilemap priority 0 across rows
# 96-103 and one of priority 1 across rows 104-119, with backdrop above,
# then lays four 32x32 sprites across all three.  Each sprite's OAM
# priority equals its palette index.  What must happen, from the header of
# that source: priority 3 shows over both bands, priority 2 shows over the
# priority-0 band and is hidden by the priority-1 one, and priorities 0 and
# 1 are hidden by both and show only against the backdrop.
BANDS = ((88, 96, "backdrop"), (96, 104, "BG pri 0"), (104, 120, "BG pri 1"))
OVER_BAND = {0: (True, False, False), 1: (True, False, False),
             2: (True, True, False), 3: (True, True, True)}


def check_bg_priority(path, name):
    """Which of an object and a background wins, band by band.

    The two OAM priority bits do not order objects against each other --
    obj-priority settles that -- they choose which of four places the
    object takes in the layer order against the backgrounds.  This reads
    that ordering straight off the screen: at every pixel a sprite paints,
    either the sprite's own colour is there or it is not.
    """
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()
    vram = bytes(machine.ppu.vram_bytes)
    base = obj_base_bytes(machine)
    cgram = machine.ppu.cgram_list
    at = screen(machine)

    def rgb(index):
        word = cgram[index]
        return tuple(((word >> s) & 31) << 3 | ((word >> s) & 31) >> 2
                     for s in (0, 5, 10))

    bad = 0
    for s, x, y, tile, palette, w, h in sprites(machine)[:4]:
        for (top, bottom, what), want in zip(BANDS, OVER_BAND[s]):
            shown = hidden = 0
            for py in range(max(top, y) - y, min(bottom, y + h) - y):
                for px in range(w):
                    if not 0 <= x + px < 256:
                        continue
                    index = obj_pixel(vram, base, tile, palette, w, px, py)
                    if not index:
                        continue
                    if at(x + px, y + py) == rgb(index):
                        shown += 1
                    else:
                        hidden += 1
            total = shown + hidden
            if not total:
                print("  %-14s sprite %d over %-9s nothing to compare"
                      % (name, s, what))
                bad += 1
            elif (shown == total) == want:
                print("  %-14s sprite %d (OAM priority %d) is %s the %-9s"
                      " ok  %d pixels"
                      % (name, s, s, "over " if want else "under", what, total))
            else:
                bad += 1
                print("  %-14s sprite %d (OAM priority %d) should be %s the %s,"
                      " but %d of %d pixels show the sprite"
                      % (name, s, s, "over" if want else "under", what,
                         shown, total))
    return bad


def check_colours(path, name):
    """Every opaque pixel of every sprite, against the colour it asks for.

    obj-palettes.sfc draws the same glyphs eight times through OBJ
    palettes 0 to 7, so what is being read here is that the three palette
    bits in OAM reach CGRAM at 128 + 16p and nowhere else.  Nothing
    overlaps, so each pixel has exactly one right answer.
    """
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()
    vram = bytes(machine.ppu.vram_bytes)
    base = obj_base_bytes(machine)
    cgram = machine.ppu.cgram_list
    at = screen(machine)

    bad = 0
    for s, x, y, tile, palette, w, h in sprites(machine):
        if not (0 <= x < 256 - w and y + h <= 224):
            continue
        drawn = wrong = 0
        for py in range(h):
            for px in range(w):
                index = obj_pixel(vram, base, tile, palette, w, px, py)
                if not index:
                    continue
                drawn += 1
                word = cgram[index]
                want = tuple(((word >> sh) & 31) << 3 | ((word >> sh) & 31) >> 2
                             for sh in (0, 5, 10))
                if at(x + px, y + py) != want:
                    wrong += 1
        if not drawn:
            continue
        if wrong:
            bad += 1
            print("  %-14s sprite %d, palette %d: %d of %d pixels are not the"
                  " colour it asked for" % (name, s, palette, wrong, drawn))
        else:
            print("  %-14s sprite %d ok  palette %d, %d pixels"
                  % (name, s, palette, drawn))
    return bad


def check(path, name):
    if name == "obj-palettes":
        return check_colours(path, name)
    if name == "obj-bg-priority":
        return check_bg_priority(path, name)
    if name in PIXELWISE:
        return check_priority(path, name, PIXELWISE[name])
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
        flat_got = [c for row in got for c in row]
        flat_want = [t for row in want for t in row]
        if all(matches(g, t) for g, t in zip(flat_got, flat_want)):
            print("  %-14s (%3d,%3d) ok    %s" % (
                name, x, y, " ".join(show(c) for row in got for c in row)))
        else:
            bad += 1
            print("  %-14s (%3d,%3d) WRONG" % (name, x, y))
            print("      want %s" % " ".join(showwant(t) for t in flat_want))
            print("      got  %s" % " ".join(show(c) for row in got for c in row))
    return bad


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    if os.path.isdir(target):
        names = (sorted(EXPECTED) + sorted(PIXELWISE)
                 + ["obj-bg-priority", "obj-palettes"]
                 + ["obj-size-grid-%d" % i for i in range(8)])
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
