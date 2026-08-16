"""Gamepad mapping and configuration, without a gamepad.

`snes/gamepad.py` is three hundred lines and nothing named it in a test.
Most of it needs a physical controller and cannot be checked here, but three
things can, and all three break in ways a player notices immediately.

The button table is written out twice, here and in `snes/system.pyx`, and a
drift between them would send every press to the wrong bit.

The default layout is a claim: the SNES face buttons sit a quarter turn from
an Xbox pad, so it maps by position rather than by label -- SNES B, the
bottom button, onto the pad's bottom button, which is called A.  Anyone
"correcting" that to match the labels would break every player's hands, and
the only thing standing in the way is that it is written down.

And a per-device entry in the config has to override only what it names, so
a controller with one odd button does not lose the other eleven.
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (name, got, want))


def main():
    from snes.system import BUTTONS as CONSOLE
    from snes import gamepad

    # One table, written twice.
    check("the pad's button bits are the console's", gamepad.BUTTONS, CONSOLE)

    # The quarter turn, by position rather than label.
    m = gamepad.DEFAULT_MAPPING
    check("SNES B is the pad's bottom button", m["B"], "a")
    check("SNES A is the pad's right button", m["A"], "b")
    check("SNES Y is the pad's left button", m["Y"], "x")
    check("SNES X is the pad's top button", m["X"], "y")
    check("every SNES button is mapped",
          sorted(m), sorted(CONSOLE))

    # A per-device entry overrides only what it names.
    home = tempfile.mkdtemp(prefix="pysnes-pads-")
    path = os.path.join(home, "gamepad.json")
    with open(path, "w") as fh:
        json.dump({"_default": {"buttons": {}, "functions": {}},
                   "Odd Pad": {"buttons": {"START": "guide"}}}, fh)
    pads = gamepad.Pads(config_path=path)
    try:
        buttons, functions = pads._mapping_for("Odd Pad")
        check("the named button is overridden", buttons["START"], "guide")
        check("the rest are the defaults", buttons["B"], m["B"])
        check("all twelve survive an override", len(buttons), len(CONSOLE))
        check("functions fall back too", functions, gamepad.DEFAULT_FUNCTIONS)

        # An unknown controller gets the defaults, not an error.
        buttons, _ = pads._mapping_for("Never Seen Before")
        check("an unknown pad gets the default layout", buttons, dict(m))
    finally:
        pads.close()

    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  " + line)
        return 1
    print("all gamepad mapping tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
