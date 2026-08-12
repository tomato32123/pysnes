"""Boot a directory of hardware test ROMs and capture what each one says.

These are the ROMs that report on themselves: they run a suite on the real
chip's terms and print the verdict to the screen.  Unlike the tests in this
repository they were not written from the same reading of the documentation
the emulator was, which is the whole point of them -- they can say the
emulator is *wrong* rather than merely *unchanged*.

They are not in this repository and should not be: put them somewhere of
your own and point this at it.

    python tools/testroms.py <dir> [--frames 1500] [--shots out-dir]

These ROMs say pass or fail in the backdrop colour before they say it in
words -- blue for passed, red for failed -- so the verdict is read from a
pixel and the screenshot is kept for the detail.  A test that scrolls needs
more frames, not fewer: the summary comes last, and a run that has not
finished shows neither colour.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.screenshot import write_png

EXTENSIONS = (".sfc", ".smc")

PASSED = (0, 0, 115)
FAILED = (123, 0, 0)


def verdict(framebuffer):
    """What the backdrop says: 'passed', 'failed', or 'unfinished'."""
    counts = {}
    for y in range(20, 60):                     # above the first line of text
        for x in range(0, 512, 8):
            i = (y * 512 + x) * 4
            rgb = (framebuffer[i + 2], framebuffer[i + 1], framebuffer[i])
            counts[rgb] = counts.get(rgb, 0) + 1
    backdrop = max(counts, key=counts.get)
    if backdrop == PASSED:
        return "passed"
    if backdrop == FAILED:
        return "failed"
    return "unfinished"


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
    results = {}

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
        said = verdict(machine.framebuffer)
        results[said] = results.get(said, 0) + 1
        print("%-28s %-10s %d frames -> %s" % (name, said, args.frames, shot))
    print()
    print("summary:", dict(sorted(results.items())))
    return 1 if results.get("passed", 0) != len(roms) else 0


if __name__ == "__main__":
    sys.exit(main())
