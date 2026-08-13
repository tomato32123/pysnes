"""Run krom's SNES test ROMs and read each verdict out of VRAM.

These are per-instruction hardware tests -- one ROM per 65816 instruction, per
SPC700 instruction and per GSU instruction -- and they are the external
authority the CPU and the SuperFX have not had.  Each ROM walks an
instruction's addressing modes, and for each one prints a row of `PASS` or
`FAIL` for eight combinations of width and decimal mode.

Two things make them readable without looking at the picture.

The text is written into the tile map as ASCII: the font is loaded so that
tile number equals character code, and the ROM writes only the low byte of
each map entry.  So the screen can be read back as characters straight out of
VRAM, which is exact where reading pixels would be guesswork.

And a failure *stops* the ROM: the failing branch prints `FAIL` and then
branches to itself.  So a run that reaches the last addressing mode with no
`FAIL` on any page has passed everything, and a run that stops early says
where it stopped.

    python tools/kromtests.py <dir-or-rom> [--frames N] [-v]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

COLS, ROWS = 32, 28
MAX_FRAMES = 1200
SETTLE = 150                    # frames of an unchanging screen before giving up


def map_base(machine):
    """Byte address of the BG1 tile map, from the PPU's own state."""
    for line in machine.ppu.dump().splitlines():
        if line.startswith("BG map"):
            first = re.search(r"'(0x[0-9a-f]+)'", line)
            if first:
                return int(first.group(1), 16) * 2
    return 0xF800


def screen(machine, base):
    vram = bytes(machine.ppu.vram_bytes)
    out = []
    for r in range(ROWS):
        row = vram[base + r * COLS * 2:base + r * COLS * 2 + COLS * 2:2]
        out.append("".join(chr(c) if 32 <= c < 127 else " " for c in row).rstrip())
    return out


def run(path, max_frames=MAX_FRAMES):
    """Boot the ROM and collect every distinct page it draws."""
    machine = System(path)
    # The map base is read from the PPU rather than assumed, and re-read until
    # it is set: at reset $2107 is zero, and the ROM points it at the map it
    # has just filled a few instructions later.
    base = 0
    pages, last, still = [], None, 0
    for _ in range(max_frames):
        machine.run_frame()
        base = map_base(machine) or base
        page = screen(machine, base)
        if page == last:
            still += 1
            if still >= SETTLE and pages:
                break
            continue
        still = 0
        last = page
        if any("PASS" in r or "FAIL" in r for r in page):
            if not pages or pages[-1] != page:
                pages.append(page)
    return machine, pages


def heading(page):
    """The line naming what this page tested, e.g. `ADC addr (Opcode: $6D)`."""
    for row in page[3:7]:
        if row.strip() and "Modes" not in row and "---" not in row:
            return row.strip()
    return "?"


def verdict(path, verbose=False):
    machine, pages = run(path)
    name = machine.cart.title.strip()
    if not pages:
        print("  %-28s %-34s no result on screen" % (os.path.basename(path), name))
        return False

    failures = []
    for page in pages:
        for row in page:
            if "FAIL" in row:
                failures.append((heading(page), row.strip()))

    ok = not failures
    print("  %-28s %-34s %s  (%d pages)"
          % (os.path.basename(path), name, "ok" if ok else "FAIL", len(pages)))
    for where, row in failures:
        print("      %s" % where)
        print("        %s" % row)
    if verbose and failures:
        for row in pages[-1]:
            print("      | %s" % row)
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "-v" in sys.argv
    target = args[0] if args else "/home/moto/Projects/rom/testroms/krom"

    if os.path.isdir(target):
        roms = sorted(os.path.join(target, f) for f in os.listdir(target)
                      if f.lower().endswith((".sfc", ".smc")))
    else:
        roms = [target]

    print("%d test ROMs\n" % len(roms))
    bad = []
    for rom in roms:
        try:
            if not verdict(rom, verbose):
                bad.append(os.path.basename(rom))
        except Exception as exc:
            print("  %-28s raised %s: %s"
                  % (os.path.basename(rom), type(exc).__name__, exc))
            bad.append(os.path.basename(rom))

    print()
    if bad:
        print("%d of %d failed: %s" % (len(bad), len(roms), ", ".join(bad)))
        return 1
    print("all %d passed" % len(roms))
    return 0


if __name__ == "__main__":
    sys.exit(main())
