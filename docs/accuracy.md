# Accuracy: where this emulator stands, and the route onward

The goal is to move from "the games I tried work" to "the hardware behaves the
way the documentation says, and a test proves it".

## Where it is now

Timing is already bus-access driven rather than per-frame. Every S-CPU memory
access charges the master-clock cost of its address (6, 8 or 12 cycles), the
H and V counters advance inside that same call, and scanline events -- V-blank,
NMI, H/V IRQ, HDMA, the automatic controller read -- fire from it. The APU
runs on its own crystal and is caught up by `run_until(master_clock)`.

What that leaves:

| | state |
| --- | --- |
| S-CPU timing | bus-access driven, with the datasheet's idle-cycle rules |
| Central scheduler | events on absolute deadlines: line, HDMA, IRQ, joypad, APU |
| PPU granularity | **scanline** — a mid-scanline register write is lost |
| Deterministic trace | instructions and bus accesses, with the master clock |
| Test-ROM regression suite | CPU flags, addressing, decimal, RMW, block move, timing |
| Cartridge | LoROM / HiROM / ExHiROM, interleaved dumps, PAL; no coprocessors |

So: past "it boots", into "individual behaviours are pinned by tests", with the
PPU's time resolution as the largest single gap.

## Why the trace and the tests came first

Restructuring the core around a scheduler is the kind of change that breaks
things silently. Doing it without a regression net means discovering the
breakage later, in a game, with no idea which change caused it. The trace and
the suite are the net; the scheduler work goes on top of them.

## The tooling

`tools/asm65816.py` is a 65816 assembler whose opcode table is *inverted from
the disassembler's*, so the two cannot disagree about what a byte means.
Test ROMs therefore live in this repository as source, and a failing case can
be extended by writing more assembly rather than by hunting for a binary.

`tools/testrom.py` wraps a fragment of assembly in a real LoROM image with a
valid header and vectors, boots it through the ordinary cartridge path, and
reads back the values the program wrote to WRAM. Tests assert on what the
emulated program computed, not on emulator internals.

`tools/tracefmt.py` renders a trace as one canonical line per instruction,
led by the master clock:

```
00000102 00:8018 A9 LDA #$41   A:0000 X:00FF Y:0000 S:1FFF D:0000 DB:00 P:37 E:0
```

Two traces line up cycle by cycle, so `first_difference` points at the exact
instruction where this emulator and a reference part company. That is the
mechanism that makes "compare against bsnes or ares" practical.

Timing assertions read naturally once the cost model is stated: a bus access
to slow ROM is 8 master cycles and an internal cycle is 6, so an instruction
the datasheet calls "2 cycles" -- one fetch plus one internal cycle -- must
take 14. `LDA dp` must take 24, and 30 when the low byte of D is non-zero.

## The scheduler

Time has one owner.  Anything that must happen at a particular master cycle is
registered with an absolute deadline, and `tick()` advances the clock and fires
whatever has come due, earliest first.  The hot path stays a single comparison:
the earliest deadline is cached and recomputed only when an event is scheduled
or fires.

This replaced a version that tested every condition on every bus access and
acted on line boundaries, which put an IRQ at the first access *after* its dot
rather than at the dot, and ran HDMA at the end of a line rather than at dot
278.  Events now sit where the hardware puts them.

Interrupts are still taken at instruction boundaries, as on hardware, so a
measured handler entry can be up to one instruction late.  The timing tests
assert on the accumulated span across many periods rather than on individual
gaps, which distinguishes that jitter from drift.

## Next

1. **Dot-aware PPU.** Render from the H counter so that scroll, mode, window,
   colour-math and brightness writes take effect from the dot they happen at.
   This is what mid-scanline effects need, and it is the part of the internal
   state a 2.5D renderer would consume.
2. **Widen the suite** as each of those lands: PPU register timing, H/V
   counter latching, DMA and HDMA cycle costs, NMI and IRQ edges.

## Parked

Compatibility work stopped here deliberately; the notes are kept so it can be
resumed without rediscovery.

* **SA-1** (Super Mario RPG, Kirby Super Deluxe, Jikkyou Oshaberi Parodius,
  Mini Yonku Shining Scorpion), **S-DD1** (Street Fighter Zero 2) and
  **DSP-1** (Super Mario Kart) are unimplemented. The 65816 core is reusable
  for SA-1; the work is the memory map, the message registers and deciding
  which processor owns the bus.
* **Super Puyo Puyo 2 Remix** stalls before it ever touches the APU ports: the
  SPC700 is still in the IPL at $FFD2 waiting for $CC. Its NMI handler runs
  once -- entered because $4200 was written with NMI already flagged -- does
  `INC $25`, then writes $01 to $4200, disabling NMI. The main loop then waits
  on $25, which is 0 again by the time it looks. Something re-enables NMI on
  hardware and does not here.
* **Mix** and **SMWREX** are ROM hacks; both are PAL images and neither draws.
* **Super Famista 5** draws for around 1500 frames and then goes black.
