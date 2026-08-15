"""Rewind must land back on states the machine actually passed through."""
import hashlib, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv, any_rom, NO_ROM
from snes.system import System
from snes.rewind import Rewind

# A cartridge, any cartridge, but the same one every run: these check
# that the machine can be put back exactly as it was, and that needs
# something real to put back rather than a particular thing.
ROM = from_argv(quiet=True) if len(sys.argv) > 1 else any_rom()


def digest(machine):
    return hashlib.sha1(bytes(machine.framebuffer)).hexdigest()


def main():
    if ROM is None:
        sys.stderr.write("no cartridge to check a state against; set "
                         "PYSNES_ROMS or pass one" + chr(10))
        return NO_ROM
    s = System(ROM)
    for _ in range(1700):
        s.run_frame()

    r = Rewind(seconds=10.0, interval=3)

    # Record 300 frames, remembering the framebuffer at each captured point.
    seen = []
    for _ in range(300):
        s.run_frame()
        if r.capture(s):
            seen.append(digest(s))
    print("captured %d snapshots over 300 frames -> %s" % (len(seen), r.describe()))
    assert len(seen) == 100, "expected one snapshot per 3 frames, got %d" % len(seen)

    # Step back through them; each restore must match what was recorded there.
    steps = 0
    while r.step_back(s):
        steps += 1
        expected = seen[-1 - steps]
        assert digest(s) == expected, "rewind step %d does not match the recorded frame" % steps
        if steps >= 50:
            break
    print("stepped back %d snapshots, every frame matched" % steps)

    # History is bounded.
    r2 = Rewind(seconds=2.0, interval=3)
    for _ in range(600):
        s.run_frame()
        r2.capture(s)
    assert len(r2.frames) == r2.capacity, "ring did not cap at %d" % r2.capacity
    print("ring capped correctly: %s" % r2.describe())

    # Cost of recording, against a 16.67 ms frame budget.
    r3 = Rewind(seconds=10.0, interval=3)
    t0 = time.perf_counter()
    for _ in range(180):
        s.run_frame()
        r3.capture(s)
    with_rewind = (time.perf_counter() - t0) / 180 * 1000
    t0 = time.perf_counter()
    for _ in range(180):
        s.run_frame()
    plain = (time.perf_counter() - t0) / 180 * 1000
    overhead = with_rewind - plain
    print("frame cost: %.2f ms plain, %.2f ms while recording (+%.2f ms)"
          % (plain, with_rewind, overhead))
    # What this can honestly measure is the cost of recording, not whether the
    # frame fits in 60 Hz.  It used to assert the latter, and on a machine
    # with a browser open the same build measures anywhere from 11 to 24 ms
    # with no code change at all -- so the assertion was reporting on the
    # desktop rather than on the emulator.  The overhead is the stable number
    # and the one this test is for: it has to stay a small fraction of a
    # frame, whatever else the machine is doing.
    assert overhead < 5.0, ("recording costs %.2f ms a frame, which is too "
                            "much of the 16.67 available" % overhead)

    print("all rewind tests passed")


if __name__ == "__main__":
    main()
