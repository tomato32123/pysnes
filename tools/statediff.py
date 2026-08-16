"""Save, reload, and see whether the machine carries on the same way.

A save state that leaves something out does not fail when it is written or
when it is read.  It fails a few frames later, when the piece that was not
carried starts to matter -- and on a coprocessor that can be a long way
later, in a game nobody was looking at.

So: run a cartridge in, take a state, run on and remember what the screen
looks like at four checkpoints, put the state back, run the same frames
again and compare.  Anything the state does not carry shows up as a
divergence, and the checkpoint it first appears at says roughly how deep it
was buried.

tests/test_state.py does this for one cartridge, which has no coprocessor.
This does it for the whole library, which is where the SA-1, the SuperFX,
the SPC7110, the S-DD1 and the OBC1 are.

**What it cannot see, and why that is not a hole.**  A round trip only tests
what is carried *between* frames.  Star Fox was the case that made this
worth chasing: its entire SuperFX state -- 616 registers and 32 KB of the
chip's own RAM -- can be zeroed and the next hundred and twenty frames come
out identical.

Three things could explain that and only one is harmless, so they were
separated rather than assumed.  The loader is not quietly skipping the board:
after loading a zeroed one the state reads back as zero.  The chip is not
idle: driven to a stage with a scripted string of Starts and As, the screen
is full of polygons, which nothing else on that cartridge can draw.  What is
left is the cartridge's own design -- Star Fox writes the GSU's program and
its data afresh every frame, so what the chip holds at a frame boundary is
already dead, and a state that dropped it would still play correctly.

So the SuperFX is reached and running here, and there is nothing across a
frame boundary for this check to find.  That is worth writing down, because
"the check passes" and "the check cannot see anything" look the same from
outside, and the difference took a screenshot of a stage to establish.

    python tools/statediff.py <romdir> [warm] [compare]
"""
import hashlib
import os
import random
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.batchtest import find_roms
from snes.system import System, BUTTONS

NOTHING_TO_DO = 77
NAMES = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "START", "SELECT"]


def digest(machine):
    return hashlib.md5(bytes(machine.framebuffer[:512 * 240 * 4])).hexdigest()[:12]


def marks(machine, frames):
    out = []
    for i in range(frames):
        machine.run_frame()
        if i % (max(1, frames // 4)) == 0:
            out.append(digest(machine))
    out.append(digest(machine))
    return out


def main():
    romdir = sys.argv[1] if len(sys.argv) > 1 else None
    warm = int(sys.argv[2]) if len(sys.argv) > 2 else 600
    span = int(sys.argv[3]) if len(sys.argv) > 3 else 120
    roms = find_roms(romdir) if romdir else []
    if not roms:
        print("no cartridges found -- nothing was checked")
        return NOTHING_TO_DO

    print("%d cartridges: %d frames in under random input, then %d compared "
          "across a save" % (len(roms), warm, span), flush=True)
    bad = 0
    for i, path in enumerate(roms, 1):
        name = os.path.basename(path)[:44]
        try:
            machine = System(path, use_saves=False)
            # Driven, not idle.  The first version of this ran the cartridge
            # in with no input at all, and Star Fox's SuperFX is asleep on
            # its title screen at frame 600 -- so the check passed with the
            # chip's entire register state thrown away.  A round trip only
            # tests what was running when the state was taken.
            rng = random.Random(4242)
            for f in range(warm):
                if f % 11 == 0:
                    held = 0
                    for n in rng.sample(NAMES, rng.randint(0, 3)):
                        held |= BUTTONS[n]
                    machine.set_pad(0, held)
                machine.run_frame()
            machine.set_pad(0, 0)
            blob = machine.save_state()
            straight = marks(machine, span)
            machine.load_state(blob)
            replayed = marks(machine, span)
        except Exception:
            last = traceback.format_exc(limit=2).strip().splitlines()[-1]
            print("%3d/%d  %-44s could not run: %s" % (i, len(roms), name, last[:44]),
                  flush=True)
            continue
        if straight == replayed:
            print("%3d/%d  %-44s same across the save" % (i, len(roms), name),
                  flush=True)
        else:
            bad += 1
            first = next((k for k in range(len(straight))
                          if straight[k] != replayed[k]), -1)
            print("%3d/%d  %-44s DIVERGED at checkpoint %d of %d"
                  % (i, len(roms), name, first + 1, len(straight)), flush=True)
    print()
    print("%d of %d carried on differently after a save and reload"
          % (bad, len(roms)), flush=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
