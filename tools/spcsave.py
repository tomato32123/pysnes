"""Write the APU's current state out as an .spc file.

Two reasons, and the second is why it exists.

The first is that this is what an SPC file is for: a snapshot of the sound
chip in the middle of a game, which any player can pick up.

The second is comparison.  A dump written here can be played by someone
else's implementation of the same chip, and the two waveforms compared --
and because both start from bytes this file wrote, a difference is a
difference in the chips rather than in the games or in how each side
guessed at a starting state.  Playing the shipped test dumps had the
opposite problem: each side restored them its own way, so a difference
could always be blamed on the restoring.

    python tools/spcsave.py <rom> <out.spc> [--frames N]
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System

SIGNATURE = b"SNES-SPC700 Sound File Data v0.30"


def snapshot(machine):
    """The APU as 66048 bytes in the published SPC layout."""
    apu = machine.apu
    state = apu.state_ints()
    pc, a, x, y, sp, psw = state[0], state[1], state[2], state[3], state[4], state[5]

    out = bytearray(0x10200)
    out[0:33] = SIGNATURE
    out[33] = 26
    out[34] = 26
    out[35] = 26          # an ID666 tag is present, even if it is all blanks
    out[36] = 30          # version minor
    struct.pack_into("<HBBBBB", out, 0x25, pc, a, x, y, psw, sp)

    ram = apu.ram_bytes
    out[0x100:0x10100] = ram

    # $F0-$FF are registers rather than memory, and the RAM underneath them
    # is not what they hold, so each one is written into the dump from the
    # chip's own state.  Leaving them as they lay was worth one silent
    # recording: a player restoring the control register from RAM turned the
    # timers off and left the boot ROM mapped over the program.
    ipl_enabled = state[6]
    dsp_addr = state[18]
    aux4, aux5 = state[19], state[20]
    timer_target = state[29:32]
    timer_enabled = state[41:44]
    control = ((timer_enabled[0] & 1) | ((timer_enabled[1] & 1) << 1)
               | ((timer_enabled[2] & 1) << 2) | ((ipl_enabled & 1) << 7))
    out[0x100 + 0xF1] = control
    out[0x100 + 0xF2] = dsp_addr
    # The ports are recorded as the SPC700 sees them -- the console's side of
    # each pair -- which is the direction a player will restore.
    for i in range(4):
        out[0x100 + 0xF4 + i] = state[21 + i]
    out[0x100 + 0xF8] = aux4
    out[0x100 + 0xF9] = aux5
    for i in range(3):
        out[0x100 + 0xFA + i] = timer_target[i] & 0xFF

    regs = apu.dsp.registers
    for i in range(128):
        out[0x10100 + i] = regs[i]
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("out")
    ap.add_argument("--frames", type=int, default=1800)
    args = ap.parse_args()

    machine = System(args.rom)
    for i in range(args.frames):
        # Press start and A now and then, so a game that waits at a title
        # screen reaches the part of itself that plays music.
        phase = i % 120
        if phase == 0:
            machine.set_pad(0, 0x1000)
        elif phase == 8:
            machine.set_pad(0, 0)
        elif phase == 60:
            machine.set_pad(0, 0x80)
        elif phase == 68:
            machine.set_pad(0, 0)
        machine.run_frame()

    data = snapshot(machine)
    with open(args.out, "wb") as fh:
        fh.write(data)
    print("wrote %s (%d bytes) after %d frames" % (args.out, len(data), args.frames))
    return 0


if __name__ == "__main__":
    sys.exit(main())
