"""Rewind must land back on states the machine actually passed through."""
import hashlib, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System
from snes.rewind import Rewind

ROM = from_argv()


def digest(machine):
    return hashlib.sha1(bytes(machine.framebuffer)).hexdigest()


def main():
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
    print("frame cost: %.2f ms plain, %.2f ms while recording (+%.2f ms)"
          % (plain, with_rewind, with_rewind - plain))
    assert with_rewind < 16.67, "recording pushes the frame over the 60 Hz budget"

    print("all rewind tests passed")


if __name__ == "__main__":
    main()
