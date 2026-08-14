"""Draw the phone's screen on a machine that is not a phone.

The Android front end can be run here, at a phone's shape, against the
dummy video driver -- so the layout, the picture fitting and the on-screen
pad can be looked at before anything is packaged or installed.  What it
cannot show is how fast a phone would do it; that needs a phone.

    python tools/androidpreview.py <rom> [width] [height]
"""
import os
import sys

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "android"))

import pygame
from snes.system import System, BUTTONS
import main as app

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "shots", "android.png")


def main():
    if len(sys.argv) < 2:
        print("usage: androidpreview.py <rom> [width] [height]")
        return 1
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 2340
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 1080
    frames = 900

    pygame.init()
    screen = app.Screen(size=(width, height))
    machine = System(sys.argv[1])
    for i in range(frames):
        # Press start and A now and then, so the picture is a game rather
        # than a title card.
        phase = i % 120
        if phase == 0:
            machine.set_pad(0, BUTTONS["START"])
        elif phase == 8:
            machine.set_pad(0, 0)
        elif phase == 60:
            machine.set_pad(0, BUTTONS["A"])
        elif phase == 68:
            machine.set_pad(0, 0)
        machine.run_frame()

    screen.show(machine.framebuffer, machine.visible_height)
    # Show the pad as a player would see it with a thumb on the d-pad and A.
    screen.draw_pad(BUTTONS["RIGHT"] | BUTTONS["A"])
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    pygame.image.save(screen.window, OUT)
    print("wrote %s at %dx%d" % (OUT, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
