"""Boot a directory of hardware test ROMs and capture what each one says.

These are the ROMs that report on themselves: they run a suite on the real
chip's terms and print the verdict to the screen.  Unlike the tests in this
repository they were not written from the same reading of the documentation
the emulator was, which is the whole point of them -- they can say the
emulator is *wrong* rather than merely *unchanged*.

They are not in this repository and should not be: put them somewhere of
your own and point this at it.

    python tools/testroms.py <dir> [--frames 1500] [--shots out-dir]

The verdict is a picture, so this writes one per ROM and leaves the reading
to a human.  A test that scrolls needs more frames, not fewer: the summary
line comes last.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.screenshot import write_png

EXTENSIONS = (".sfc", ".smc")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("romdir")
    ap.add_argument("--frames", type=int, default=1500)
    ap.add_argument("--shots", default="shots/testroms")
    args = ap.parse_args()

    roms = sorted(os.path.join(args.romdir, f) for f in os.listdir(args.romdir)
                  if f.lower().endswith(EXTENSIONS))
    if not roms:
        raise SystemExit("no test ROMs in %s" % args.romdir)
    os.makedirs(args.shots, exist_ok=True)

    for path in roms:
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            machine = System(path)
        except Exception as exc:
            print("%-28s could not be loaded: %s" % (name, exc))
            continue
        for _ in range(args.frames):
            machine.run_frame()
        shot = os.path.join(args.shots, name + ".png")
        write_png(shot, machine.framebuffer)
        print("%-28s %d frames -> %s" % (name, args.frames, shot))


if __name__ == "__main__":
    main()
