"""Run the machine from reset and print an instruction trace."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System
from tools.disasm import trace_line

ROM = from_argv()
N = int(sys.argv[1]) if len(sys.argv) > 1 else 60

s = System(ROM)
print(s.cart.describe()); print()
for i in range(N):
    print("%5d %s" % (i, trace_line(s)))
    s.step(1)
print()
print("final:", s.state())
