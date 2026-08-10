import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System
ROM = from_argv()
s = System(ROM)
for frames in (1, 10, 60, 200, 400):
    while s.frame_count < frames:
        s.run_frame()
    print("=== after %d frames ===" % frames)
    print(s.ppu.dump().rstrip())
    print("VRAM words set: %d/32768   CGRAM entries set: %d/256   OAM bytes set: %d/544"
          % (s.ppu.vram_nonzero(), s.ppu.cgram_nonzero(), s.ppu.oam_nonzero()))
    print("CPU:", s.state())
    print()
