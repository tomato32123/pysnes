"""Run for a while and report where the machine ends up, plus raw speed."""
import os, sys, time, collections
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System
from tools.disasm import trace_line

ROM = from_argv()
N = int(sys.argv[1]) if len(sys.argv) > 1 else 3_000_000

s = System(ROM)
t0 = time.perf_counter()
s.step(N)
dt = time.perf_counter() - t0

print("executed %d instructions in %.3fs -> %.2f M instr/s" % (N, dt, N / dt / 1e6))
print("emulated %.3f s of SNES time (%.1f%% of real time)"
      % (s.master_clock / 21477272, (s.master_clock / 21477272) / dt * 100))
print("frames:", s.frame_count)
print("state :", s.state())
print()

# Where is it spending its time?
hits = collections.Counter()
for _ in range(20000):
    r = s.cpu.regs
    hits[(r["pb"], r["pc"])] += 1
    s.step(1)
print("hottest PCs:")
for (pb, pc), n in hits.most_common(12):
    print("  %02X:%04X  %6d" % (pb, pc, n))
print()
print("current:", trace_line(s))
print("APU ports cpu->apu:", s.apu.ports_from_cpu, " apu->cpu:", s.apu.ports_to_cpu)
print("PPU: forced_blank=%d brightness=%d bgmode=%d" % (
    s.ppu.__class__ and 0 or 0, 0, 0) if False else "")
