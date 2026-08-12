"""Compare this DSP against a reference implementation, sample by sample.

`difftrace.py` does this for the CPU and has never had a reference to compare
against.  This one does: blargg's S-DSP, the same author as the test ROMs and
the closest thing to a hardware measurement that can be run here.  It is not
in this repository and should not be; build it yourself:

    git clone https://github.com/blarggs-audio-libraries/snes_spc
    cd snes_spc/snes_spc
    cp <this repo>/tools/dspprobe.cpp .
    g++ -O2 -o dspprobe dspprobe.cpp SPC_DSP.cpp

then point this at it:

    python tools/dspdiff.py path/to/dspprobe

Both sides are driven by the same script of register writes and both are read
through the registers a program can see -- ENVX, OUTX and ENDX -- so a
difference is a difference a game could notice.  The script writes every
register that matters before anything is measured, because the two come out of
reset with different ideas of what they hold and that is not what is being
tested.

The output is the first sample where the two disagree, with a few either side.
That turns "the emulator sounds slightly wrong" into a place to look, which is
the whole point of the exercise.
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU

KON, KOFF, ADSR0, ADSR1, GAIN = 0x4C, 0x5C, 0x05, 0x06, 0x07

# Every register that matters, written before anything is measured.
PREAMBLE = ([(0, r, 0x00) for r in range(0x80) if (r & 0x0F) not in (0x0C, 0x0D)]
            + [(0, 0x6C, 0x20),                    # FLG: running, not muted
               (0, 0x0C, 0x7F), (0, 0x1C, 0x7F),   # main volume
               (0, 0x2C, 0x00), (0, 0x3C, 0x00),   # echo volume off
               (0, 0x0D, 0x00), (0, 0x7D, 0x00),   # no feedback, no echo buffer
               (0, 0x5D, 0x02),                    # sample directory at $0200
               (0, 0x00, 0x7F), (0, 0x01, 0x7F),   # voice 0 volume
               (0, 0x02, 0x00), (0, 0x03, 0x10),   # voice 0 pitch, 1:1
               (0, 0x04, 0x00),                    # voice 0 uses source 0
               (0, 0x7C, 0x00)])                   # clear ENDX

SCRIPTS = {
    "gain direct":       [(0, GAIN, 0x7F), (0, ADSR0, 0x00), (1, KON, 0x01)],
    "gain linear up":    [(0, GAIN, 0xDF), (0, ADSR0, 0x00), (1, KON, 0x01)],
    "gain two-slope up": [(0, GAIN, 0xFF), (0, ADSR0, 0x00), (1, KON, 0x01)],
    "gain linear down":  [(0, GAIN, 0x9F), (0, ADSR0, 0x00), (1, KON, 0x01)],
    "gain exp down":     [(0, GAIN, 0xBF), (0, ADSR0, 0x00), (1, KON, 0x01)],
    "adsr full":         [(0, ADSR0, 0x8F), (0, ADSR1, 0xFF), (1, KON, 0x01)],
    "adsr SL=0":         [(0, ADSR0, 0x8F), (0, ADSR1, 0x1F), (1, KON, 0x01)],
    "attack then gain":  [(0, ADSR0, 0x8F), (0, ADSR1, 0xFF), (1, KON, 0x01),
                          (20, ADSR0, 0x00), (20, GAIN, 0xFF)],
    "gain then adsr":    [(0, GAIN, 0x7F), (0, ADSR0, 0x00), (1, KON, 0x01),
                          (30, ADSR0, 0x8F), (30, ADSR1, 0xFF)],
    "kon then koff":     [(0, GAIN, 0x7F), (0, ADSR0, 0x00), (1, KON, 0x01),
                          (40, KOFF, 0x01)],
}

# One BRR block that loops on itself, so a voice keyed on has something to play
# for as long as a script wants.
SAMPLE_ADDR = 0x0200
DIRECTORY = bytes([0x00, 0x02, 0x00, 0x02])
BLOCK = bytes([0xB3] + [0x77] * 8)


def ours(script, samples):
    apu = APU()
    apu.do_reset()
    apu.poke_ram(SAMPLE_ADDR, DIRECTORY)
    apu.poke_ram(SAMPLE_ADDR + 4, BLOCK)
    by_sample = {}
    for at, reg, val in script:
        by_sample.setdefault(at, []).append((reg, val))
    out = []
    for s in range(samples):
        for reg, val in by_sample.get(s, ()):
            apu.dsp_write(reg, val)
        apu.dsp_tick(1)
        r = apu.dsp.registers
        out.append((r[0x08], r[0x09], r[0x7C]))
    return out


def theirs(probe, script, samples):
    text = "".join("%d %d %d\n" % w for w in script)
    p = subprocess.run([probe, str(samples)], input=text,
                       capture_output=True, text=True)
    out = []
    for line in p.stdout.splitlines():
        f = line.split()
        out.append((int(f[1], 16), int(f[2], 16), int(f[3], 16)))
    return out


def compare(probe, name, script, samples):
    a = ours(PREAMBLE + script, samples)
    b = theirs(probe, PREAMBLE + script, samples)
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print("%-20s differs at sample %d" % (name, i))
            print("      %5s  %-14s %s" % ("", "ours", "reference"))
            for j in range(max(0, i - 2), min(n, i + 3)):
                print("      %5d  %02X %02X %02X       %02X %02X %02X%s"
                      % (j, a[j][0], a[j][1], a[j][2], b[j][0], b[j][1], b[j][2],
                         "   <-" if j == i else ""))
            return False
    print("%-20s agrees over %d samples" % (name, n))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probe", help="the built reference probe")
    ap.add_argument("--samples", type=int, default=160)
    args = ap.parse_args()
    if not os.path.exists(args.probe):
        raise SystemExit("no such probe: %s (see the docstring)" % args.probe)

    bad = 0
    for name, script in SCRIPTS.items():
        if not compare(args.probe, name, script, args.samples):
            bad += 1
    print()
    print("%d of %d scripts differ" % (bad, len(SCRIPTS)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
