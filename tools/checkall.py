"""Run every oracle this project has, and say which ones did not run.

The lesson of the last day is that a check nobody runs is a check that
does not exist.  A 65C816 test ROM sat in the library printing "Failed"
at test 27 for months; a cartridge's own self-test said its clock was
wrong; a proof about colour maths measured on a console sat beside its
own answer -- all of them here, none of them read.

So this is the list, in one place, with one command.  What it reports is
three things and keeps them apart: passed, failed, and could not run.
The third is not a pass.  Most of these need ROMs that are deliberately
not in this repository, and a missing ROM must never be silence.

    python tools/checkall.py [--slow]

Without --slow the ones that take minutes are listed but not run.
"""
import os
import subprocess
import sys

from tools.romarg import ROMS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (name, argv, slow) -- slow ones need whole libraries or thousands of frames.
CHECKS = [
    ("unit tests", [sys.executable, "tools/runtests.py"], False),
    ("65C816 and SPC700 test ROMs", [sys.executable, "tools/cputest.py"], True),
    ("krom instruction ROMs", [sys.executable, "tools/kromtests.py"], True),
    ("krom PPU references", [sys.executable, "tools/ppucompare.py"], True),
    ("neser OBJ behaviour", [sys.executable, "tools/objglyphs.py"], False),
    ("colour-halve order", [sys.executable, "tools/colourmath.py"], False),
    ("VRAM address remapping", [sys.executable, "tools/vmaintest.py"], True),
    ("SPC dumps, by ear", [sys.executable, "tools/spcplay.py"], True),
    ("interrupt timing after DMA", [sys.executable, "tools/dmairqtest.py"], True),
    # The DSP against blargg's own implementation, sample by sample.  The
    # probe is built from his library rather than kept here; without it this
    # reports "could not run", which is not a pass.
    ("DSP against blargg's, by sample",
     [sys.executable, "tools/dspdiff.py",
      os.environ.get("PYSNES_DSPPROBE", "dspprobe-not-built")], True),
    # A game's own music through both implementations: the SPC700 running
    # its driver, the timers and the DSP together.  Needs the same player
    # as above; without it this reports "could not run".
    ("a game's music, both chips",
     [sys.executable, "tools/apucompare.py",
      ROMS + "/snes/Super_Mario_World_(U)/MARIO.SMC"], True),
    ("SPC7110 cartridge self-test",
     [sys.executable, "tools/spc7110check.py",
      ROMS + "/snes/Momotarou Dentetsu Happy (Japan)/"
      "Momotarou Dentetsu Happy (Japan).sfc"], True),
]


def run(argv):
    try:
        done = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                              timeout=3600)
    except FileNotFoundError as exc:
        return None, str(exc)
    except subprocess.TimeoutExpired:
        return None, "took longer than an hour"
    tail = [l for l in done.stdout.strip().splitlines() if l.strip()]
    return done.returncode, tail[-1] if tail else "(said nothing)"


def main():
    slow = "--slow" in sys.argv
    passed = failed = skipped = 0
    for name, argv, is_slow in CHECKS:
        if is_slow and not slow:
            print("  %-32s skipped (pass --slow to run it)" % name)
            skipped += 1
            continue
        code, last = run(argv)
        if code is None:
            print("  %-32s COULD NOT RUN -- %s" % (name, last))
            skipped += 1
        elif code == 0:
            print("  %-32s ok    %s" % (name, last[:60]))
            passed += 1
        else:
            print("  %-32s FAILED  %s" % (name, last[:60]))
            failed += 1

    print()
    print("%d passed, %d failed, %d not run" % (passed, failed, skipped))
    if skipped and not failed:
        print("something not run is not something that passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
