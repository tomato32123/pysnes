"""Break a real play loop down into per-stage costs and report the tail.

Stutter is about the worst frames, not the average, so this reports
percentiles: anything over 16.67 ms is a dropped frame at 60 Hz.
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame
from tools.romarg import from_argv
from snes.system import System
from snes.rewind import Rewind

ROM = from_argv()
N = int(sys.argv[1]) if len(sys.argv) > 1 else 900
SCALE = 3
W, H = 256, 239

s = System(ROM)
for _ in range(1700):
    s.run_frame()

pygame.mixer.pre_init(frequency=32000, size=-16, channels=2, buffer=1024)
pygame.init()
screen = pygame.display.set_mode((W * SCALE, H * SCALE))
pygame.display.set_caption("pysnes frame profile")
audio = None
try:
    from snes.audioout import AudioOut
    audio = AudioOut(s)
except Exception as e:
    print("no audio:", e)

rewind = Rewind(seconds=20.0)
stages = {k: [] for k in ("emulate", "rewind", "blit", "flip", "audio", "total")}

for i in range(N):
    pygame.event.pump()
    t0 = time.perf_counter()
    s.run_frame()
    t1 = time.perf_counter()
    rewind.capture(s)
    t2 = time.perf_counter()
    frame = pygame.image.frombuffer(bytes(s.framebuffer), (W, H), "BGRA")
    pygame.transform.scale(frame, screen.get_size(), screen)
    t3 = time.perf_counter()
    pygame.display.flip()
    t4 = time.perf_counter()
    if audio:
        audio.feed(s)
    t5 = time.perf_counter()
    stages["emulate"].append((t1 - t0) * 1000)
    stages["rewind"].append((t2 - t1) * 1000)
    stages["blit"].append((t3 - t2) * 1000)
    stages["flip"].append((t4 - t3) * 1000)
    stages["audio"].append((t5 - t4) * 1000)
    stages["total"].append((t5 - t0) * 1000)

pygame.quit()


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p / 100.0))]


print()
print("%-9s %8s %8s %8s %8s %8s" % ("stage", "mean", "p50", "p90", "p99", "max"))
print("-" * 54)
for k in ("emulate", "rewind", "blit", "flip", "audio", "total"):
    v = stages[k]
    print("%-9s %8.2f %8.2f %8.2f %8.2f %8.2f"
          % (k, sum(v) / len(v), pct(v, 50), pct(v, 90), pct(v, 99), max(v)))
over = sum(1 for x in stages["total"] if x > 16.67)
print()
print("frames over the 16.67 ms budget: %d / %d (%.1f%%)" % (over, N, over * 100.0 / N))
