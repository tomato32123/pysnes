"""Check VRAM address remapping, by the one property that proves it works.

$2115's low bits remap the VRAM address so a game can write tile data in the
order it is convenient to generate rather than the order the PPU wants.
undisbeliever's ROMs come in pairs: one writes the data plainly with no
remapping, the other writes it in a different order with remapping switched
on, and **both must produce exactly the same picture**.

That makes them checkable without a reference image and without a test ROM
that prints anything.  If remapping were ignored, the second of each pair
would come out scrambled; if it were applied when it should not be, the first
would.  Identical is the answer, and it is an answer no test written inside
this project could give, because it does not depend on this project's reading
of what the remapping rule is -- only on the two ways of writing agreeing.

    python tools/vmaintest.py [dir]
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

ROOT = "/home/moto/Projects/rom/testroms/higan"
DEFAULT_DIR = ROOT + "/undisbeliever-ppu-bg"
MODE7_DIR = ROOT + "/undisbeliever-ppu-mode7"
FRAMES = 120

# Each group must render identically, whatever it renders.
PAIRS = [
    ("1bpp", ["vmain-1bpp-no-remapping", "vmain-1bpp-with-remapping"]),
    ("2bpp", ["vmain-2bpp-no-remapping", "vmain-2bpp-with-remapping",
              "vmain-2bpp-split-with-remapping"]),
    ("4bpp", ["vmain-4bpp-no-remapping", "vmain-4bpp-with-remapping",
              "vmain-4bpp-no-remapping-word", "vmain-4bpp-with-remapping-word"]),
    ("8bpp", ["vmain-8bpp-no-remapping", "vmain-8bpp-with-remapping"]),
]

# Mode 7 keeps its tiles and its tilemap interleaved in one place, so the
# remapping has more to get wrong there than anywhere else.  Four ROMs
# write the same picture four ways -- plainly, tilemap first, and through
# the eight- and ten-bit remappings -- and the collection's own README
# says all four show the same image when VMAIN is right.
MODE7 = [
    ("mode 7", ["vmain-mode7-image-no-remapping",
                "vmain-mode7-image-tilemap",
                "vmain-mode7-image-with-8bit-remapping",
                "vmain-mode7-image-with-10bit-remapping"]),
]


def render(path):
    machine = System(path)
    for _ in range(FRAMES):
        machine.run_frame()
    fb = bytes(machine.framebuffer)
    return hashlib.sha1(fb).hexdigest(), any(fb[i:i + 3] != b"\0\0\0"
                                             for i in range(0, len(fb), 4 * 997))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    groups = [(l, root, n) for l, n in PAIRS]
    if len(sys.argv) <= 1:
        groups += [(l, MODE7_DIR, n) for l, n in MODE7]
    bad = 0
    for label, root, names in groups:
        digests = {}
        blank = []
        for name in names:
            path = os.path.join(root, name + ".sfc")
            if not os.path.exists(path):
                print("  %-8s %s is not here" % (label, name))
                bad += 1
                continue
            digest, drew = render(path)
            digests[name] = digest
            if not drew:
                blank.append(name)
        if not digests:
            continue
        agreed = len(set(digests.values())) == 1
        # A pair that agrees on a blank screen agrees on nothing.
        if blank:
            print("  %-8s drew nothing: %s" % (label, ", ".join(blank)))
            bad += 1
        elif agreed:
            print("  %-8s ok    %d ROMs, one picture" % (label, len(digests)))
        else:
            bad += 1
            print("  %-8s DIFFER" % label)
            for name, digest in digests.items():
                print("      %-38s %s" % (name, digest[:12]))

    print()
    print("%s" % ("remapping agrees with plain writing everywhere" if not bad
                  else "%d group(s) disagree" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
