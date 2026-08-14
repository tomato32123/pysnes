"""Put many cartridges' screens on one sheet, so they can be read at a glance.

Four hundred and twenty-six test ROMs in this library print something and
cannot be read by tools/verdicts.py, because that turns tile numbers into
letters and most of these carry a font of their own.  Their screens are
perfectly legible; they are just legible to an eye rather than to a table.

So this stops trying to decode them and lays them out instead: nine screens
to a sheet, in the order printed to stdout, at the size the console drew
them.  A sheet is 768x672 -- large enough to read a results table, small
enough that nine of them arrive together.

    python tools/contactsheet.py <rom> [more roms...] [--frames 600]
    python tools/contactsheet.py --dir <directory> [--limit 45]

Sheets are written to shots/sheet00.png and so on, and the roster goes to
stdout so a screen can be matched back to the cartridge that drew it.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

SRC_W = 512                      # what the PPU hands over, two columns a dot
VISIBLE = 256                    # dots across, once the pairs are halved
COLS, ROWS = 3, 3                # screens to a sheet
GAP = 8                          # so one screen's edge is not another's
SUFFIXES = (".smc", ".sfc", ".swc", ".fig")


def write_png(path, width, height, pixels):
    """pixels is a bytearray of RGB triples, row-major."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)                                # filter: none
        raw += pixels[y * width * 3:(y + 1) * width * 3]

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                            8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        fh.write(chunk(b"IEND", b""))


def one_screen(path, frames):
    """Run a cartridge and return its picture as (height, RGB rows).

    The right column of each pair is the picture: the PPU writes two per dot
    so the hires modes have somewhere to put their left half.
    """
    machine = System(path)
    for _ in range(frames):
        machine.run_frame()
    fb = machine.framebuffer
    height = max(1, min(machine.visible_height, 240))
    out = bytearray(VISIBLE * height * 3)
    for y in range(height):
        base = y * SRC_W * 4
        row = y * VISIBLE * 3
        for x in range(VISIBLE):
            i = base + (x * 2 + 1) * 4
            out[row + x * 3 + 0] = fb[i + 2]
            out[row + x * 3 + 1] = fb[i + 1]
            out[row + x * 3 + 2] = fb[i + 0]
    return height, out


def enlarge(width, height, pixels, scale):
    """Nearest-neighbour, so a 8x8 font stays a font rather than a smudge."""
    out = bytearray(width * scale * height * scale * 3)
    for y in range(height):
        src = y * width * 3
        row = bytearray()
        for x in range(width):
            row += pixels[src + x * 3:src + x * 3 + 3] * scale
        for r in range(scale):
            dst = ((y * scale + r) * width * scale) * 3
            out[dst:dst + len(row)] = row
    return out


def sheet(screens, path, scale=1):
    """Lay out up to COLS*ROWS screens on one image."""
    cell_h = max(h for h, _ in screens)
    width = COLS * VISIBLE + (COLS + 1) * GAP
    height = ROWS * cell_h + (ROWS + 1) * GAP
    # A middling grey ground: black would merge with the screens, white
    # would glare against text that is mostly white on black.
    pixels = bytearray([0x40] * (width * height * 3))
    for i, (h, data) in enumerate(screens):
        col, row = i % COLS, i // COLS
        x0 = GAP + col * (VISIBLE + GAP)
        y0 = GAP + row * (cell_h + GAP)
        for y in range(h):
            dst = ((y0 + y) * width + x0) * 3
            src = y * VISIBLE * 3
            pixels[dst:dst + VISIBLE * 3] = data[src:src + VISIBLE * 3]
    if scale > 1:
        pixels = enlarge(width, height, pixels, scale)
        width, height = width * scale, height * scale
    write_png(path, width, height, pixels)


def main():
    args = sys.argv[1:]
    frames = 600
    if "--frames" in args:
        i = args.index("--frames")
        frames = int(args[i + 1])
        del args[i:i + 2]
    scale = 1
    if "--scale" in args:
        i = args.index("--scale")
        scale = int(args[i + 1])
        del args[i:i + 2]
    limit = 45
    if "--limit" in args:
        i = args.index("--limit")
        limit = int(args[i + 1])
        del args[i:i + 2]

    roms = []
    if args and args[0] == "--dir":
        for dirpath, _dirs, files in os.walk(args[1]):
            for name in sorted(files):
                if name.lower().endswith(SUFFIXES):
                    roms.append(os.path.join(dirpath, name))
        roms = roms[:limit]
    else:
        roms = args
    if not roms:
        print("usage: python tools/contactsheet.py <rom>... | --dir <dir>")
        return 1

    outdir = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "shots")
    os.makedirs(outdir, exist_ok=True)

    batch, sheets = [], 0
    for path in roms:
        try:
            batch.append(one_screen(path, frames))
        except Exception as exc:
            print("  (skipped %s: %s)" % (os.path.basename(path), exc))
            continue
        print("  sheet%02d position %d: %s"
              % (sheets, len(batch), os.path.basename(path)))
        if len(batch) == COLS * ROWS:
            sheet(batch, os.path.join(outdir, "sheet%02d.png" % sheets), scale)
            print("shots/sheet%02d.png" % sheets)
            batch, sheets = [], sheets + 1
    if batch:
        sheet(batch, os.path.join(outdir, "sheet%02d.png" % sheets), scale)
        print("shots/sheet%02d.png" % sheets)
    return 0


if __name__ == "__main__":
    sys.exit(main())
