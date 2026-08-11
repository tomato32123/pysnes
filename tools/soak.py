"""Long run with pseudo-random input, watching for hangs, crashes and stalls."""
import os, random, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System, BUTTONS
from tools.screenshot import write_png

ROM = from_argv()
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shots")
NAMES = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "START"]

total = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
rng = random.Random(1234)
s = System(ROM)

t0 = time.perf_counter()
last_pc = None
stall = 0
held = 0
for f in range(total):
    if f % 12 == 0:
        held = 0
        for n in rng.sample(NAMES, rng.randint(0, 2)):
            held |= BUTTONS[n]
        s.set_pad(0, held)
    s.run_frame()

    if f % 2000 == 0:
        pc = s.cpu.regs["pc"]
        nb = sum(1 for i in range(0, 512 * 478 * 4, 4)
                 if s.framebuffer[i] or s.framebuffer[i + 1] or s.framebuffer[i + 2])
        print("f=%-6d %s  non-black=%-6d apu_clock=%d"
              % (f, s.state(), nb, s.apu.regs["clock"]), flush=True)
        if pc == last_pc:
            stall += 1
        last_pc = pc
        write_png(os.path.join(OUT, "soak_%05d.png" % f), s.framebuffer)

dt = time.perf_counter() - t0
print("soak finished: %d frames in %.1fs -> %.1f fps" % (total, dt, total / dt), flush=True)
print("final:", s.state(), flush=True)
