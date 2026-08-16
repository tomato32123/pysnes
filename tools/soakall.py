"""Every cartridge, random input, watching for anything that stops.

Random input goes wide, not deep.  It rarely gets a menu-driven game into
play: Star Fox needs Start on a rhythm and then A, and four thousand frames
of random presses never find it.  Mixing the two -- random play with a
steady confirm underneath -- is worse than either, because the random
directions move the cursor and B backs out of what Start just entered.
Reaching gameplay reliably wants a script per cartridge, which is a lot of
work for coverage this already has by accident on the games that start
themselves.

The verdict is whether the picture still *moves*, not what the last frame
happened to hold.  The first version of this called eight cartridges black
because frame 4000 was mid-fade or in a menu; all eight were drawing again a
few hundred frames later.  A snapshot cannot tell a hang from a blink.
"""
import hashlib, os, random, sys, time, traceback

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.batchtest import find_roms
from snes.system import System, BUTTONS

NAMES = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "START", "SELECT"]
# Four thousand frames, about a minute of play.  The list below was drawn up
# at that length and does not hold at a shorter one: at 600 frames five more
# cartridges are still on a boot logo and look stopped.  A soak that runs for
# less than its list was measured over reports faults that are only impatience.
FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
if FRAMES < 4000:
    print("warning: the expected-static list was drawn up over 4000 frames; "
          "%d will report cartridges that are merely still booting" % FRAMES,
          flush=True)
WATCH = 8                       # samples over the last quarter of the run
# Cartridges whose picture is meant to stand still, with why.  Anything else
# that stops moving is a regression and this says so.
EXPECTED = {
    "DSP1 Tech Demo (USA) (Demo).sfc": "no header anywhere in the image",
    "Mix.smc": "the image is destroyed, not the emulator",
    "SMWREX.smc": "the image is destroyed, not the emulator",
    "Dungeon Master (Japan).sfc": "DSP firmware is not here",
    "Planet's Champ TG 3000, The (Japan).sfc": "DSP firmware is not here",
    "SD Gundam GX (Japan).sfc": "DSP-3 firmware is not here",
    "Rockman_X_2_(J).smc": "the CX4 is not emulated; its error screen is static",
    # Reached an actual game -- board drawn, pieces placed -- and waiting for
    # a move its coprocessor is not here to compute.  It moved before the
    # interrupt timing was corrected, which only means random input used to
    # leave it wandering the menus; getting further in is not a regression.
    "Hayazashi Nidan Morita Shougi (Japan).sfc":
        "the ST01x is not emulated; it sits on a board waiting for a move",
    "Momotarou Dentetsu Happy (Japan).sfc": "its own check program, which ends",
    "Tengai Makyou Zero (Japan).sfc": "its own check program, which ends",
}

roms = find_roms(sys.argv[1] if len(sys.argv) > 1 else
                 os.path.join(os.environ.get("PYSNES_ROMS", ""), "snes"))
if not roms:
    print("no cartridges found -- nothing was checked")
    sys.exit(77)
print("%d cartridges, %d frames each" % (len(roms), FRAMES), flush=True)
bad = 0
for i, path in enumerate(roms, 1):
    name = os.path.basename(path)[:44]
    rng = random.Random(4242)
    t0 = time.perf_counter()
    try:
        m = System(path, use_saves=False)
        shots, every = [], max(1, FRAMES // (4 * WATCH))
        for f in range(FRAMES):
            if f % 11 == 0:
                held = 0
                for n in rng.sample(NAMES, rng.randint(0, 3)):
                    held |= BUTTONS[n]
                m.set_pad(0, held)
            m.run_frame()
            if f >= FRAMES * 3 // 4 and f % every == 0:
                shots.append(hashlib.md5(bytes(m.framebuffer[:512*240*4])).hexdigest())
        note = ""
        if len(set(shots)) <= 1:
            why = EXPECTED.get(os.path.basename(path))
            if why:
                note = "  stands still: %s" % why
            else:
                note = "  STOPPED MOVING"
                bad += 1
        print("%3d/%d  %-44s %5.1fs  %d distinct frames%s"
              % (i, len(roms), name, time.perf_counter() - t0,
                 len(set(shots)), note), flush=True)
    except Exception:
        if os.path.basename(path) not in EXPECTED:
            bad += 1
        print("%3d/%d  %-44s CRASH %s" % (i, len(roms), name,
              traceback.format_exc(limit=2).strip().splitlines()[-1][:60]), flush=True)
print()
print("%d of %d stopped moving or crashed unexpectedly" % (bad, len(roms)), flush=True)
sys.exit(1 if bad else 0)
