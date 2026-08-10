"""End-to-end DSP check against an independent decoder.

A known BRR sample is written into APU RAM, one voice is pointed at it, and
the mixed output is compared with the same sample decoded by a plain Python
reference.  This covers BRR decoding, the sample directory, key-on, the pitch
counter, interpolation and the output mix in one shot -- the parts that are
otherwise only judged by ear.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.apu import APU

SAMPLE_BASE = 0x1000
DIR_BASE = 0x0200


def clamp16(v):
    return max(-32768, min(32767, v))


def clip15(v):
    v = ((v & 0x7FFF) << 1) & 0xFFFF
    if v & 0x8000:
        v -= 0x10000
    return v >> 1


def encode_brr(samples, loop=False):
    """Pack samples into BRR blocks with filter 0, which round-trips exactly
    for values that fit the chosen shift."""
    blocks = bytearray()
    for i in range(0, len(samples), 16):
        chunk = list(samples[i:i + 16])
        chunk += [0] * (16 - len(chunk))
        peak = max(abs(v) for v in chunk) or 1
        shift = 0
        while shift < 12 and (peak >> shift) > 7 * 2:
            shift += 1
        header = (shift << 4) | 0x00
        last = i + 16 >= len(samples)
        if last:
            header |= 0x01 | (0x02 if loop else 0)
        blocks.append(header)
        for j in range(0, 16, 2):
            a = max(-8, min(7, round(chunk[j] / (1 << shift) * 2)))
            b = max(-8, min(7, round(chunk[j + 1] / (1 << shift) * 2)))
            blocks.append(((a & 0x0F) << 4) | (b & 0x0F))
    return bytes(blocks)


def reference_decode(brr):
    """Decode BRR exactly the way the hardware does, in plain Python."""
    out, p1, p2, a = [], 0, 0, 0
    while a < len(brr):
        header = brr[a]
        shift, filt = header >> 4, (header >> 2) & 3
        for i in range(16):
            byte = brr[a + 1 + (i >> 1)]
            nib = (byte >> 4) if (i & 1) == 0 else (byte & 0x0F)
            if nib > 7:
                nib -= 16
            v = (nib << shift) >> 1 if shift <= 12 else (-2048 if nib < 0 else 0)
            if filt == 1:
                v += p1 + ((-p1) >> 4)
            elif filt == 2:
                v += (p1 << 1) + ((-(p1 * 3)) >> 5) - p2 + (p2 >> 4)
            elif filt == 3:
                v += (p1 << 1) + ((-(p1 * 13)) >> 6) - p2 + ((p2 * 3) >> 4)
            v = clip15(clamp16(v))
            p2, p1 = p1, v
            out.append(v)
        if header & 1:
            break
        a += 9
    return out


def build_apu(brr, pitch):
    apu = APU()
    apu.poke_ram(SAMPLE_BASE, brr)
    # Directory entry 0: start and loop both at the sample.
    apu.poke_ram(DIR_BASE, bytes([SAMPLE_BASE & 0xFF, SAMPLE_BASE >> 8,
                                  SAMPLE_BASE & 0xFF, SAMPLE_BASE >> 8]))
    apu.dsp_write(0x5D, DIR_BASE >> 8)          # DIR
    apu.dsp_write(0x6C, 0x00)                   # FLG: run, unmute, echo off
    apu.dsp_write(0x0C, 0x7F)                   # MVOL left
    apu.dsp_write(0x1C, 0x7F)                   # MVOL right
    apu.dsp_write(0x2C, 0x00)                   # EVOL off
    apu.dsp_write(0x3C, 0x00)
    apu.dsp_write(0x00, 0x7F)                   # voice 0 volume
    apu.dsp_write(0x01, 0x7F)
    apu.dsp_write(0x02, pitch & 0xFF)
    apu.dsp_write(0x03, pitch >> 8)
    apu.dsp_write(0x04, 0x00)                   # source 0
    apu.dsp_write(0x05, 0x00)                   # ADSR off -> use GAIN
    apu.dsp_write(0x07, 0x7F)                   # GAIN: direct, full level
    apu.dsp_write(0x4C, 0x01)                   # KON voice 0
    return apu


def collect(apu, n):
    out = []
    for _ in range(n):
        apu.dsp_tick(1)
        out.append(apu.dsp.voice_state[0]["out"])
    return out


def test_playback_matches_reference():
    # A sawtooth exercises the decoder harder than a sine.
    src = [int(8000 * (((i % 40) / 20.0) - 1.0)) for i in range(320)]
    brr = encode_brr(src, loop=False)
    expected = reference_decode(brr)

    apu = build_apu(brr, 0x1000)               # 1:1 playback
    raw = collect(apu, 300)

    # Key-on is delayed a few samples and the 4-tap interpolator adds its own
    # latency, so search a small window rather than pinning an exact offset.
    def correlate(offset):
        got = raw[offset:offset + 200]
        ref = expected[:len(got)]
        num = sum(a * b for a, b in zip(got, ref))
        den = math.sqrt(sum(a * a for a in got) * sum(b * b for b in ref)) or 1.0
        return num / den

    best_offset, corr = max(((o, correlate(o)) for o in range(12)), key=lambda t: t[1])
    got = raw[best_offset:best_offset + 200]
    peak_got = max(abs(v) for v in got)
    peak_ref = max(abs(v) for v in expected[:200])
    print("  1:1 playback: correlation %.4f at offset %d, peak %d vs reference %d"
          % (corr, best_offset, peak_got, peak_ref))
    assert corr > 0.95, "voice output does not track the decoded sample (%.3f)" % corr
    assert best_offset <= 8, "unexpectedly large playback latency (%d)" % best_offset
    assert 0.7 < peak_got / peak_ref < 1.3, "amplitude is off by more than 30%"


def test_pitch_scales_playback_rate():
    """At double pitch the sample must run out in half the time."""
    src = [int(6000 * math.sin(2 * math.pi * i / 32.0)) for i in range(320)]
    brr = encode_brr(src, loop=False)

    lengths = {}
    for name, pitch in (("1x", 0x1000), ("2x", 0x2000)):
        apu = build_apu(brr, pitch)
        # Play until the voice releases itself at the end flag.
        ticks = 0
        for _ in range(2000):
            apu.dsp_tick(1)
            ticks += 1
            if apu.dsp.registers[0x7C] & 1:      # ENDX
                break
        lengths[name] = ticks
    ratio = lengths["1x"] / float(lengths["2x"])
    print("  sample ran %d ticks at 1x, %d at 2x -> ratio %.2f"
          % (lengths["1x"], lengths["2x"], ratio))
    assert 1.8 < ratio < 2.2, "pitch does not scale the playback rate"


def test_gain_controls_level():
    src = [int(8000 * math.sin(2 * math.pi * i / 24.0)) for i in range(320)]
    brr = encode_brr(src, loop=True)

    peaks = {}
    for gain in (0x7F, 0x40, 0x00):
        apu = build_apu(brr, 0x1000)
        apu.dsp_write(0x07, gain)
        apu.dsp_write(0x4C, 0x01)
        peaks[gain] = max(abs(v) for v in collect(apu, 200))
    print("  peak at gain 7F/40/00: %d / %d / %d"
          % (peaks[0x7F], peaks[0x40], peaks[0x00]))
    assert peaks[0x00] == 0, "zero gain still produced output"
    assert peaks[0x40] < peaks[0x7F], "gain does not scale the level"
    ratio = peaks[0x40] / float(peaks[0x7F])
    assert 0.4 < ratio < 0.6, "half gain should roughly halve the level (got %.2f)" % ratio


def test_echo_fir_gain_is_unity():
    """The echo FIR taps are signed 8-bit with 128 meaning unity.

    Dividing each tap by 64 instead of 128 gives the filter 2x gain, which with
    any feedback turns the echo into a loud resonant ring that buries the music.
    Send a signal through the echo path alone, with a single unity tap and no
    feedback, and the level that comes back must match what went in.
    """
    src = [int(8000 * math.sin(2 * math.pi * i / 16.0)) for i in range(320)]
    brr = encode_brr(src, loop=True)

    apu = build_apu(brr, 0x1000)
    dry = max(abs(v) for v in collect(apu, 600))

    apu = build_apu(brr, 0x1000)
    apu.dsp_write(0x0C, 0x00)          # MVOL off: hear the echo only
    apu.dsp_write(0x1C, 0x00)
    apu.dsp_write(0x2C, 0x7F)          # EVOL full
    apu.dsp_write(0x3C, 0x7F)
    apu.dsp_write(0x0D, 0x00)          # EFB: no feedback
    apu.dsp_write(0x4D, 0x01)          # EON voice 0
    apu.dsp_write(0x6D, 0x40)          # ESA: buffer at $4000, clear of the sample
    apu.dsp_write(0x7D, 0x01)          # EDL: 2048 bytes = 512 samples
    apu.dsp_write(0x6C, 0x00)          # FLG: echo writes enabled
    apu.dsp_write(0x0F, 127)           # C0 = unity
    for tap in range(1, 8):
        apu.dsp_write((tap << 4) + 0x0F, 0)
    apu.dsp_write(0x4C, 0x01)

    apu.dsp_tick(1000)                 # let the delay line fill and settle
    blob = apu.dsp.take_samples(99999)
    vals = [int.from_bytes(blob[i:i+2], "little", signed=True) for i in range(0, len(blob), 2)]
    wet = max(abs(v) for v in vals[-2000:]) if vals else 0

    ratio = wet / float(dry or 1)
    print("  dry voice peak %d, echo-only peak %d -> ratio %.2f" % (dry, wet, ratio))
    assert 0.7 < ratio < 1.3, ("echo path gain is %.2f, expected about 1.0 "
                               "(2.0 means the FIR is dividing by 64 not 128)" % ratio)


def main():
    for fn in (test_playback_matches_reference,
               test_pitch_scales_playback_rate,
               test_gain_controls_level,
               test_echo_fir_gain_is_unity):
        print(fn.__name__)
        fn()
    print("all DSP tests passed")


if __name__ == "__main__":
    main()
