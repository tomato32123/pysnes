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
    Backspace(hold) rewind
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
from snes.rewind import Rewind

# What the PPU fills, and the shape of the picture it stands for.  A dot
# becomes two pixels and a frame can be two fields, so the buffer is twice
# the nominal size in each direction.
BUF_W, BUF_H = 512, 478
WIDTH, HEIGHT = 256, 224
FRAME_SECONDS = 1.0 / 60.098          # NTSC field rate

KEYMAP = {
    pygame.K_UP: "UP", pygame.K_DOWN: "DOWN",
    pygame.K_LEFT: "LEFT", pygame.K_RIGHT: "RIGHT",
    pygame.K_z: "B", pygame.K_x: "A",
    pygame.K_a: "Y", pygame.K_s: "X",
    pygame.K_q: "L", pygame.K_w: "R",
    pygame.K_RETURN: "START", pygame.K_RSHIFT: "SELECT",
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
    ap.add_argument("--rewind-seconds", type=float, default=20.0,
                    help="how much rewind history to keep; 0 disables it")
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
    # The header names a chipset; the board is what was actually built
    # for it, which is not always the same thing.
    print("board      : %s" % machine.bus.board.describe())

    if args.frames:
        os.environ["SDL_VIDEODRIVER"] = "dummy"

    if not args.no_audio and not args.frames:
        pygame.mixer.pre_init(frequency=32000, size=-16, channels=2, buffer=1024)
    pygame.init()
    pygame.display.set_caption("pysnes - %s" % machine.cart.title)
    screen = pygame.display.set_mode((WIDTH * args.scale, HEIGHT * args.scale))
    surface = pygame.Surface((BUF_W, BUF_H))
    clock = pygame.time.Clock()

    audio = None
    if not args.no_audio and not args.frames:
        audio = open_audio(machine)

    pads = Pads(os.path.join(app_dir(), "config", "gamepad.json"))
    print(pads.describe())

    rewind = Rewind(seconds=args.rewind_seconds, enabled=args.rewind_seconds > 0)

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

        rewinding = (keys[pygame.K_BACKSPACE] or pads.any_function("REWIND")) and rewind.enabled
        if rewinding:
            if not rewind.step_back(machine):
                rewinding = False
        if not rewinding:
            machine.run_frame()
            rewind.capture(machine)
        frames += 1
        fps_n += 1

        blit(screen, surface, machine.framebuffer, args.scale,
             machine.visible_height)
        pygame.display.flip()

        if audio is not None and not rewinding:
            audio.feed(machine)

        if not turbo:
            clock.tick_busy_loop(60)

        now = time.perf_counter()
        if now - fps_t0 >= 2.0:
            pygame.display.set_caption(
                "pysnes - %s  [%.1f fps]%s"
                % (machine.cart.title, fps_n / (now - fps_t0),
                   "  rewind %.0fs/%.0fMB" % (rewind.seconds_held, rewind.megabytes)
                   if rewind.enabled else ""))
            fps_t0, fps_n = now, 0

        if args.frames and frames >= args.frames:
            running = False

    machine.save_sram()
    rewind.close()
    pads.close()
    pygame.quit()
    print("stopped after %d frames" % frames)
    return 0


def app_dir():
    """Where config and saves live: beside the executable when frozen."""
    if FROZEN:
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


_frame_surface = None
_frame_height = None


def blit(screen, surface, framebuffer, scale, height=224):
    """Draw the part of the buffer the PPU filled, scaled to the window.

    The buffer is always 512x478 because the PPU can emit two pixels per dot
    and two fields per frame.  How much of it is a picture depends on the
    mode, so only that much is taken and then stretched, which keeps the
    aspect right whether the game drew 224 rows or 478.

    The surface is made once and kept: `frombuffer` wraps the emulator's
    framebuffer rather than copying it, so the PPU writing into that memory is
    the same thing as the surface changing.  Rebuilding it per frame -- and
    copying a megabyte with `bytes()` to do so -- was work for nothing.
    """
    global _frame_surface, _frame_height
    if _frame_surface is None or _frame_height != height:
        full = pygame.image.frombuffer(framebuffer, (BUF_W, BUF_H), "BGRA")
        _frame_surface = full.subsurface((0, 0, BUF_W, height)) if height < BUF_H else full
        _frame_height = height
    pygame.transform.scale(_frame_surface, screen.get_size(), screen)


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
