"""VRAM address remapping, checked by two cartridges against each other.

$2115 can renumber VRAM addresses as it increments, so that a program
writing tile data in the order it happens to have it lands in the order the
PPU wants to read it.  It is easy to get subtly wrong and hard to see: the
picture is still a picture, just with its tiles shuffled.

undisbeliever's suite draws the same figure twice, once writing straight
and once through the remapping, at every bit depth.  Neither ROM says
whether it passed, and neither carries a reference picture -- but the pair
does: the two screens have to come out the same pixel for pixel, or the
remapping moved something it should not have.  Eleven cartridges with no
verdict between them turn into six answers that way.

The cartridges are not in this repository.  Set PYSNES_ROMS to where they
are, or drop them into roms/, and this runs; otherwise it skips.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import find_named, NO_ROM
from snes.system import System

FRAMES = 200
FAILURES = []

PAIRS = [
    ("vmain-1bpp-no-remapping", "vmain-1bpp-with-remapping"),
    ("vmain-2bpp-no-remapping", "vmain-2bpp-with-remapping"),
    ("vmain-2bpp-no-remapping", "vmain-2bpp-split-with-remapping"),
    ("vmain-4bpp-no-remapping", "vmain-4bpp-with-remapping"),
    ("vmain-4bpp-no-remapping-word", "vmain-4bpp-with-remapping-word"),
    ("vmain-8bpp-no-remapping", "vmain-8bpp-with-remapping"),
]


def picture(path):
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()
    fb = machine.framebuffer
    height = min(machine.visible_height, 240)
    # The right column of each pair is the picture; the left is where a hires
    # mode would put its other half.
    return bytes(fb[y * 512 * 4 + (x * 2 + 1) * 4 + c]
                 for y in range(height) for x in range(256) for c in (0, 1, 2))


def main():
    paths = {}
    for a, b in PAIRS:
        for name in (a, b):
            if name not in paths:
                paths[name] = find_named(name + ".sfc")
    if any(p is None for p in paths.values()):
        sys.stderr.write("undisbeliever's VMAIN cartridges are not on this "
                         "machine; set PYSNES_ROMS to where they are" + chr(10))
        return NO_ROM

    for a, b in PAIRS:
        pa, pb = picture(paths[a]), picture(paths[b])
        differing = sum(1 for x, y in zip(pa, pb) if x != y)
        print("  %-30s = %-32s %s"
              % (a, b, "ok" if differing == 0 else "DIFFERS"))
        if differing:
            FAILURES.append("%s and %s differ in %d of %d bytes"
                            % (a, b, differing, len(pa)))
    print()
    if FAILURES:
        for line in FAILURES:
            print("  " + line)
        return 1
    print("remapping puts every bit depth where the straight write does")
    return 0


if __name__ == "__main__":
    sys.exit(main())
