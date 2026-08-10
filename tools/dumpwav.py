"""Record the emulator's audio output to a .wav so it can be listened to.

    python tools/dumpwav.py <rom> [seconds] [--skip N]

Runs headless, so it is unaffected by the audio device or the frame pacing.
"""
import os, struct, sys, wave
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System

ROM = from_argv()
args = [a for a in sys.argv[1:] if not a.startswith("--")]
seconds = float(args[0]) if args else 10.0
skip = 1750
for a in sys.argv[1:]:
    if a.startswith("--skip"):
        skip = int(a.split("=", 1)[1]) if "=" in a else skip

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shots",
                   "audio.wav")
os.makedirs(os.path.dirname(out), exist_ok=True)

s = System(ROM)
print("skipping %d frames to get past the boot sequence..." % skip)
for _ in range(skip):
    s.run_frame()
s.apu.dsp.take_samples(999999)

frames = int(seconds * 60.0988)
data = bytearray()
for _ in range(frames):
    s.run_frame()
    data += s.apu.dsp.take_samples(999999)

with wave.open(out, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(32000)
    w.writeframes(bytes(data))

n = len(data) // 4
vals = struct.unpack("<%dh" % (len(data) // 2), bytes(data))
peak = max(abs(v) for v in vals) if vals else 0
rms = (sum(v * v for v in vals) / len(vals)) ** 0.5 if vals else 0
print("wrote %s" % out)
print("  %d stereo frames = %.2f s at 32000 Hz" % (n, n / 32000.0))
print("  peak %d (%.0f%% of full scale), rms %.0f" % (peak, peak / 327.67, rms))
