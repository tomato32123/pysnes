"""Load an SPC state into the APU and listen to what it says.

Three of the test files in this library are not ROMs and not pictures:
they are SPC dumps that report their verdict in beeps -- one low tone for
a pass, a low then a high for the first failure, and further tones for the
code.  Nothing here could read them, because nothing here could load an
SPC and nothing here had ever looked at the sound as data.

So this does both.  The dump's RAM, its processor registers and its DSP
registers go into the APU, the APU is run on its own with no console
around it, and the samples that come out are cut into bursts and each
burst's pitch measured by how often it crosses zero.  The sequence of low
and high tones is then read against the table the tests' own readme
gives.

It is worth being clear about what this checks and what it does not: the
tones say whether the SPC700 and the DSP came up in the state the test
expects, which is what these particular dumps are for.  It is not a
judgement of how the audio sounds, and nothing here can make one -- this
machine has no speakers, and no test ROM can hear itself.

    python tools/spcplay.py [file.spc ...]
"""
import os
import struct
import sys

from tools.romarg import ROMS

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU

DEFAULT_DIR = (ROMS + "/testroms/higan/jonasquinn-test-roms/"
               "spc_loader_tests")

# The SPC file layout, which is published: a signature, the processor's
# registers, 64 KB of RAM and then the DSP's 128 registers.
OFF_PC = 0x25
OFF_RAM = 0x100
OFF_DSP = 0x10100
SAMPLE_RATE = 32000

# From the tests' readme: the first tone is always low, and what follows
# says what went wrong.
VERDICTS = {
    ("low",): "passed",
    ("low", "high"): "general failure",
    ("low", "high", "low"): "failure code 2",
    ("low", "high", "high"): "failure code 3",
}


def load(apu, data):
    """Put an SPC dump's state into the APU."""
    if len(data) < OFF_DSP + 128:
        raise ValueError("too short to be an SPC dump")
    for addr in range(0x10000):
        apu.poke_ram(addr, bytes([data[OFF_RAM + addr]]))
    # $F0-$FF are registers, not memory: the timers, the test register and
    # the port latches.  A dump records what they held, and restoring them
    # means writing them as the processor would -- filling RAM at those
    # addresses would leave the timers stopped and the ports empty, and the
    # tests that check exactly this would then be measuring the loader.
    # $F0-$F3 are the test and control registers and the DSP address;
    # $F8 and $F9 are two spare registers that look like memory and are
    # not; $FA-$FC are the timers' periods.  $FD-$FF are the timers'
    # outputs and are read-only, so a dump's values there cannot be put back.
    # $F0 is deliberately not restored.  It is a write-only test register --
    # nothing can read it back, so a dump's byte at that address is whatever
    # happened to be in the RAM underneath rather than what the register
    # held.  Writing it turned the timers off in every dump taken from a
    # game, because that byte was zero and one of its bits has to be set for
    # a timer to count at all.
    for addr in list(range(0xF1, 0xF4)) + [0xF8, 0xF9] + list(range(0xFA, 0xFD)):
        apu.poke_reg(addr, data[OFF_RAM + addr])
    for reg in range(128):
        apu.dsp_write(reg, data[OFF_DSP + reg])
    pc, a, x, y, psw, sp = struct.unpack_from("<HBBBBB", data, OFF_PC)
    state = apu.state_ints()
    state[0], state[1], state[2], state[3], state[4], state[5] = pc, a, x, y, sp, psw
    # $F4-$F7 are two latches each, one per direction.  What a dump holds
    # there is what the SPC700 reads -- the console's side of the pair.
    for i in range(4):
        state[21 + i] = data[OFF_RAM + 0xF4 + i]
    apu.load_ints(state)

    # The timers last, and by setting their state rather than writing the
    # register that would start them: that write also empties the ports,
    # and the dividers cannot be written at any address.  Which timers run
    # is the low three bits of the control register the dump recorded.
    control = data[OFF_RAM + 0xF1]
    for i in range(3):
        apu.poke_timer(i, (control >> i) & 1, data[OFF_RAM + 0xFA + i])

    # A limitation worth stating rather than papering over.  Restoring a
    # dump through register writes cannot reproduce every end state: the
    # write that starts the timers is also the write that empties the
    # ports, and the timers' own dividers are not writable at all.  Three
    # orderings were tried; each satisfied one of the published test dumps
    # and broke another.  This one satisfies all three, and the cost is
    # that a dump taken mid-song from a game whose driver waits on a timer
    # can come up with that timer stopped.  Doing better means setting the
    # chip's state directly rather than through its registers, which is a
    # change to the APU rather than to this tool.


def samples(apu, seconds):
    """Run the APU on its own and collect what it plays, as mono."""
    out = []
    steps = int(seconds * 1024000)          # the SPC700's own clock
    done = 0
    while done < steps:
        apu.do_step()
        done += 1
        if done % 4096 == 0:
            raw = apu.dsp.take_samples(8192)
            for i in range(0, len(raw), 4):
                left = struct.unpack_from("<h", raw, i)[0]
                out.append(left)
    return out


def bursts(signal, floor=800, gap=1600):
    """Cut the signal into stretches of sound separated by quiet."""
    out = []
    start = None
    quiet = 0
    for i, v in enumerate(signal):
        if abs(v) > floor:
            if start is None:
                start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet > gap:
                out.append(signal[start:i - quiet])
                start = None
    if start is not None:
        out.append(signal[start:])
    return [b for b in out if len(b) > SAMPLE_RATE // 50]


def pitch(burst):
    """Rough frequency, from how often the wave crosses zero."""
    crossings = sum(1 for a, b in zip(burst, burst[1:]) if (a < 0) != (b < 0))
    return crossings * SAMPLE_RATE / (2.0 * max(1, len(burst)))


def listen(path, seconds=8.0):
    # Long enough for the one that fills every byte of RAM before it says
    # anything: at three seconds it had not finished and looked silent,
    # which is a good reminder that "said nothing" and "failed" are
    # different answers.
    apu = APU()
    with open(path, "rb") as fh:
        data = fh.read()
    load(apu, data)
    signal = samples(apu, seconds)
    found = bursts(signal)
    if not found:
        return None, []
    pitches = [pitch(b) for b in found]
    middle = (min(pitches) + max(pitches)) / 2.0
    # With one tone there is nothing to compare against, and the readme
    # says the first is always the low one.
    if max(pitches) - min(pitches) < 40.0:
        tones = ["low"] * len(pitches)
    else:
        tones = ["low" if p < middle else "high" for p in pitches]
    return tuple(tones), pitches


def main():
    paths = sys.argv[1:]
    if not paths:
        paths = [os.path.join(DEFAULT_DIR, n)
                 for n in sorted(os.listdir(DEFAULT_DIR))
                 if n.lower().endswith(".spc")]
    bad = 0
    for path in paths:
        name = os.path.basename(path)
        try:
            tones, pitches = listen(path)
        except Exception as exc:
            print("  %-24s would not run: %s: %s" % (name, type(exc).__name__, exc))
            bad += 1
            continue
        if not tones:
            print("  %-24s said nothing" % name)
            bad += 1
            continue
        verdict = VERDICTS.get(tones, "an unlisted sequence")
        if verdict != "passed":
            bad += 1
        print("  %-24s %-20s %s  (%s Hz)"
              % (name, " ".join(tones), verdict,
                 " ".join("%.0f" % p for p in pitches)))
    print()
    print("every dump reports a pass" if not bad
          else "%d of %d did not report a pass" % (bad, len(paths)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
