"""Explain why a ROM is not showing a picture.

Runs the machine, then reports where the CPU is spending its time, what the
PPU has been told to do, and whether the interrupt and APU handshakes are
progressing -- the usual places a boot gets stuck.

    python tools/whystuck.py <rom> [frames]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.disasm import disassemble
from tools.romarg import from_argv

ROM = from_argv()
FRAMES = int(sys.argv[1]) if len(sys.argv) > 1 else 900


def main():
    machine = System(ROM)
    print(machine.cart.describe())
    print()

    for _ in range(FRAMES):
        machine.run_frame()

    # Where is it looping?
    pcs = collections.Counter()
    reads = collections.Counter()
    for _ in range(30000):
        r = machine.cpu.regs
        pcs[(r["pb"], r["pc"])] += 1
        machine.step(1)

    print("hottest PCs over 30000 instructions:")
    total = sum(pcs.values())
    for (pb, pc), n in pcs.most_common(8):
        text, _ = disassemble(machine.bus.read, pb, pc, False, False)
        print("   %02X:%04X %5.1f%%  %s" % (pb, pc, n * 100.0 / total, text))
    span = max(pcs) [1] - min(pcs)[1] if pcs else 0
    print("   (%d distinct PCs -- %s)"
          % (len(pcs), "tight loop" if len(pcs) < 40 else "still running code"))
    print()

    print(machine.ppu.dump())
    print()
    print("VRAM words set : %d / 32768" % machine.ppu.vram_nonzero())
    print("CGRAM entries  : %d / 256" % machine.ppu.cgram_nonzero())
    print("OAM bytes set  : %d / 544" % machine.ppu.oam_nonzero())
    print()

    bus = machine.bus
    print("frame          : %d" % bus.frame)
    print("NMI enabled    : %s   IRQ mode: %d" % (bool(bus.nmi_enabled), bus.irq_mode))
    print("APU ports  cpu->apu %s   apu->cpu %s"
          % (machine.apu.ports_from_cpu, machine.apu.ports_to_cpu))
    print("SPC700         : pc=$%04X  ipl=%d  stopped=%d  clock=%d"
          % (machine.apu.regs["pc"], machine.apu.regs["ipl"],
             machine.apu.regs["stopped"], machine.apu.regs["clock"]))
    print("CPU            : %s" % machine.state())
    d = bus.dma_state()
    print("HDMA enabled   : $%02X   active %s" % (d["hdma_enabled"], d["hdma_active"]))
    print("DMA params     : %s" % d["param"])
    print("DMA B-bus      : %s" % d["bbus"])


if __name__ == "__main__":
    main()
