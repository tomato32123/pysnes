"""Compare a game's own music against another implementation of the chip.

`dspdiff.py` compares the DSP alone and finds it exact.  This compares the
whole sound chip -- the SPC700 running a game's driver, its timers, and
the DSP together -- by taking a snapshot of the APU out of a running game,
playing it here and in blargg's player, and looking at the two waveforms.

Sample-for-sample agreement is not the measure here and cannot be.  A
snapshot cannot record a timer's divider -- nothing can read it -- so the
two sides start a fraction of a tick apart and drift by a sample almost
immediately.  What can be compared is the shape: the correlation between
the two waveforms and the level of each.  A driver playing the wrong
notes, at the wrong rate, or with the wrong envelope does not correlate
at 0.98.

    PYSNES_SPCPLAYER=/path/to/play_spc python tools/apucompare.py <rom>

Build the player from blargg's library:

    git clone https://github.com/blarggs-audio-libraries/snes_spc
    cd snes_spc && g++ -O2 -I. -o play_spc demo/play_spc.c demo/demo_util.c \\
        demo/wave_writer.c snes_spc/*.cpp
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU
from snes.system import System
from tools.spcplay import load
from tools.spcsave import snapshot

SAMPLES = 30000
GOOD = 0.90            # below this the two are not playing the same thing


def ours(spc_bytes, count):
    apu = APU()
    load(apu, spc_bytes)
    out = []
    while len(out) < count + 64:
        apu.do_step()
        raw = apu.dsp.take_samples(8192)
        for i in range(0, len(raw), 4):
            out.append(int.from_bytes(raw[i:i + 2], "little", signed=True))
    return np.array(out, dtype=float)


def theirs(player, path, count):
    work = os.path.dirname(path)
    subprocess.run([player, path], cwd=work, capture_output=True, timeout=600)
    wav = os.path.join(work, "out.wav")
    with wave.open(wav) as w:
        raw = w.readframes(count)
    return np.frombuffer(raw, dtype="<i2").reshape(-1, 2)[:, 0].astype(float)


def main():
    if len(sys.argv) < 2:
        print("usage: apucompare.py <rom>")
        return 1
    # The environment wins, but there is a conventional place too: leaving
    # this to a variable alone meant the check reported "could not run" for
    # as long as nobody remembered to export it.
    player = os.environ.get("PYSNES_SPCPLAYER", "")
    if not player:
        here = os.path.expanduser("~/.local/share/pysnes/play_spc")
        if os.path.exists(here):
            player = here
    if not player or not os.path.exists(player):
        print("no reference player: set PYSNES_SPCPLAYER to a built play_spc")
        return 1

    machine = System(sys.argv[1])
    for i in range(1800):
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
    work = tempfile.mkdtemp(prefix="pysnes-apucompare-")
    path = os.path.join(work, "snapshot.spc")
    with open(path, "wb") as fh:
        fh.write(data)

    a = ours(data, SAMPLES + 128)
    b = theirs(player, path, SAMPLES + 128)
    n = min(len(a), len(b)) - 128
    best = (0, -2.0)
    for shift in range(-64, 65):
        x = a[64 + shift:64 + shift + n]
        y = b[64:64 + n]
        if x.std() == 0 or y.std() == 0:
            continue
        c = float(np.corrcoef(x, y)[0, 1])
        if c > best[1]:
            best = (shift, c)
    shift, corr = best
    x = a[64 + shift:64 + shift + n]
    y = b[64:64 + n]

    print("  ours      rms %6.0f  peak %6d" % (np.sqrt((x ** 2).mean()), np.abs(x).max()))
    print("  reference rms %6.0f  peak %6d" % (np.sqrt((y ** 2).mean()), np.abs(y).max()))
    print("  correlation %.4f at a shift of %+d samples" % (corr, shift))
    print()
    if corr >= GOOD:
        print("the two implementations are playing the same thing")
        return 0
    print("they are not playing the same thing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
