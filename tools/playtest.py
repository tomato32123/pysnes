"""Drive the machine with a scripted button sequence and capture screenshots."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System, BUTTONS
from tools.screenshot import write_png

ROM = from_argv()
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shots")


def run(machine, frames, buttons=()):
    mask = 0
    for name in buttons:
        mask |= BUTTONS[name]
    machine.set_pad(0, mask)
    for _ in range(frames):
        machine.run_frame()
    machine.set_pad(0, 0)


def shot(machine, name):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".png")
    write_png(path, machine.framebuffer)
    nb = sum(1 for i in range(0, 512 * 478 * 4, 4)
             if machine.framebuffer[i] or machine.framebuffer[i + 1] or machine.framebuffer[i + 2])
    print("%-22s frame=%-5d non-black=%d  mode=%s"
          % (name, machine.frame_count, nb, machine.ppu.dump().splitlines()[1]))
    return path


def main():
    s = System(ROM)
    run(s, 1700)
    shot(s, "01_title")

    # Start -> the file/adventure menu.
    for _ in range(3):
        run(s, 6, ("START",))
        run(s, 40)
    shot(s, "02_after_start")

    run(s, 60)
    shot(s, "03_menu")

    # Confirm the first menu entry.
    run(s, 6, ("A",))
    run(s, 90)
    shot(s, "04_after_a")

    run(s, 6, ("A",))
    run(s, 120)
    shot(s, "05_after_a2")

    run(s, 200)
    shot(s, "06_later")


if __name__ == "__main__":
    main()
