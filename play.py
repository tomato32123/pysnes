#!/usr/bin/env python3
"""pysnes -- run a SNES ROM in a window.

    python play.py <rom.smc> [--scale N] [--no-audio]

Controls
    Arrow keys      D-pad
    Z / X           B / A
    A / S           Y / X
    Q / W           L / R
    Enter           Start
    Right Shift     Select
    Tab (hold)      fast forward
    F2 / F4         save / load state
    F5              save SRAM now
    Escape          quit (SRAM is written on exit)
"""
import argparse
import os
import sys
import time

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pygame

from snes.system import System, BUTTONS
from snes.gamepad import Pads

WIDTH, HEIGHT = 256, 239
FRAME_SECONDS = 1.0 / 60.098          # NTSC field rate

KEYMAP = {
    pygame.K_UP: "UP", pygame.K_DOWN: "DOWN",
    pygame.K_LEFT: "LEFT", pygame.K_RIGHT: "RIGHT",
    pygame.K_z: "B", pygame.K_x: "A",
    pygame.K_a: "Y", pygame.K_s: "X",
    pygame.K_q: "L", pygame.K_w: "R",
    pygame.K_RETURN: "START", pygame.K_RSHIFT: "SELECT",
    pygame.K_BACKSPACE: "SELECT",
}


FROZEN = getattr(sys, "frozen", False)


def ask_for_rom():
    """No ROM on the command line: offer a file picker, or explain how to pass one."""
    try:
        import tkinter
        from tkinter import filedialog
    except ImportError:
        fail("Pass a ROM: drag a .smc onto this program, or run it from a"
             + chr(10) + "terminal with the path as its argument.")
        return None
    root = tkinter.Tk()
    root.withdraw()
    path = filedialog.askopenfilename(
        title="pysnes - choose a ROM",
        filetypes=[("SNES ROMs", "*.smc *.sfc *.fig *.swc"), ("All files", "*.*")])
    root.destroy()
    return path or None


def fail(message):
    """Report a startup problem: a dialog when frozen, stderr otherwise."""
    if FROZEN:
        try:
            import tkinter
            from tkinter import messagebox
            root = tkinter.Tk()
            root.withdraw()
            messagebox.showerror("pysnes", message)
            root.destroy()
            return 1
        except Exception:
            pass
    print(message, file=sys.stderr)
    return 1


def parse_args(argv):
    ap = argparse.ArgumentParser(description="pysnes")
    ap.add_argument("rom", nargs="?", help="path to a .smc / .sfc image")
    ap.add_argument("--scale", type=int, default=3, help="window scale factor")
    ap.add_argument("--no-audio", action="store_true", help="do not open an audio device")
    ap.add_argument("--frames", type=int, default=0,
                    help="run this many frames headless and exit (for testing)")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv or sys.argv[1:])
    if not args.rom:
        args.rom = ask_for_rom()
    if not args.rom:
        return 1
    if not os.path.exists(args.rom):
        return fail("no such ROM:" + chr(10) + args.rom)

    machine = System(args.rom)
    print(machine.cart.describe())

    if args.frames:
        os.environ["SDL_VIDEODRIVER"] = "dummy"

    pygame.init()
    pygame.display.set_caption("pysnes - %s" % machine.cart.title)
    screen = pygame.display.set_mode((WIDTH * args.scale, HEIGHT * args.scale))
    surface = pygame.Surface((WIDTH, HEIGHT))
    clock = pygame.time.Clock()

    audio = None
    if not args.no_audio and not args.frames:
        audio = open_audio(machine)

    pads = Pads(os.path.join(app_dir(), "config", "gamepad.json"))
    print(pads.describe())

    held = set()
    state_path = machine.state_path
    running = True
    frames = 0
    fps_t0 = time.perf_counter()
    fps_n = 0

    while running:
        turbo = False
        for event in pygame.event.get():
            if pads.handle_event(event):
                print(pads.describe())
                continue
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_F2:
                    save_state(machine, state_path)
                elif event.key == pygame.K_F4:
                    load_state(machine, state_path)
                elif event.key == pygame.K_F5:
                    print("SRAM saved" if machine.save_sram() else "cartridge has no SRAM")
                elif event.key in KEYMAP:
                    held.add(KEYMAP[event.key])
            elif event.type == pygame.KEYUP:
                if event.key in KEYMAP:
                    held.discard(KEYMAP[event.key])

        keys = pygame.key.get_pressed()
        turbo = keys[pygame.K_TAB] or pads.any_function("FASTFORWARD")

        if pads.pressed_once("SAVESTATE"):
            save_state(machine, state_path)
        if pads.pressed_once("LOADSTATE"):
            load_state(machine, state_path)

        mask = 0
        for name in held:
            mask |= BUTTONS[name]
        machine.set_pad(0, mask | pads.mask(0))
        machine.set_pad(1, pads.mask(1))

        machine.run_frame()
        frames += 1
        fps_n += 1

        blit(screen, surface, machine.framebuffer, args.scale)
        pygame.display.flip()

        if audio is not None:
            audio.feed(machine)

        if not turbo:
            clock.tick_busy_loop(60)

        now = time.perf_counter()
        if now - fps_t0 >= 2.0:
            pygame.display.set_caption("pysnes - %s  [%.1f fps]"
                                       % (machine.cart.title, fps_n / (now - fps_t0)))
            fps_t0, fps_n = now, 0

        if args.frames and frames >= args.frames:
            running = False

    machine.save_sram()
    pads.close()
    pygame.quit()
    print("stopped after %d frames" % frames)
    return 0


def app_dir():
    """Where config and saves live: beside the executable when frozen."""
    if FROZEN:
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def blit(screen, surface, framebuffer, scale):
    frame = pygame.image.frombuffer(bytes(framebuffer), (WIDTH, HEIGHT), "BGRA")
    if scale == 1:
        screen.blit(frame, (0, 0))
    else:
        pygame.transform.scale(frame, screen.get_size(), screen)


def open_audio(machine):
    try:
        from snes.audioout import AudioOut
    except ImportError:
        return None
    try:
        return AudioOut(machine)
    except Exception as exc:                       # audio is optional
        print("audio unavailable: %s" % exc)
        return None


def save_state(machine, path):
    try:
        blob = machine.save_state()
    except AttributeError:
        print("save states not available in this build")
        return
    with open(path, "wb") as fh:
        fh.write(blob)
    print("state saved -> %s" % path)


def load_state(machine, path):
    if not os.path.exists(path):
        print("no state file at %s" % path)
        return
    with open(path, "rb") as fh:
        blob = fh.read()
    try:
        machine.load_state(blob)
    except AttributeError:
        print("save states not available in this build")
        return
    print("state loaded")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        import traceback
        sys.exit(fail(traceback.format_exc()))
