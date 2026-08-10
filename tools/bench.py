"""Measure rendered frames per second at a given point in the game."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System

ROM = from_argv()
WARM = int(sys.argv[1]) if len(sys.argv) > 1 else 1600
N = int(sys.argv[2]) if len(sys.argv) > 2 else 300

s = System(ROM)
while s.frame_count < WARM:
    s.run_frame()

t0 = time.perf_counter()
for _ in range(N):
    s.run_frame()
dt = time.perf_counter() - t0
print("%d frames in %.3fs -> %.1f fps (%.0f%% of 60 Hz)  [mode %d]"
      % (N, dt, N / dt, N / dt / 60 * 100, s.ppu.dbg_counts()["lines"] and 0 or 0))
