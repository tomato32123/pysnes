# Road to bsnes-level accuracy

What separates "the games I tried work" from "the hardware is modelled and a
test proves it". Ordered by dependency, not by appeal. `[x]` is done, `[~]` is
partial, `[ ]` is untouched.

The short version of where the weight is: the PPU's time resolution, the
coprocessors, and — more than either — the verification apparatus that turns
a suspicion into a located defect.

## 1. Timing core

- [x] Bus-access driven CPU timing: every access charges its address's cost
- [x] Event scheduler on absolute deadlines (line, HDMA, IRQ, joypad, APU)
- [x] Interrupts taken at instruction boundaries, as on hardware
- [ ] **DMA cycle exactness**: alignment to the 8-cycle DMA clock, the CPU
      stall, per-channel and per-transfer overhead measured rather than assumed
- [ ] **HDMA init and reload timing**: the init pass at the top of the frame,
      indirect reloads, channels disabled mid-frame
- [ ] **DRAM refresh**: 40 cycles stolen once per scanline, at a fixed dot
- [ ] **Short and long scanlines**: 1360-cycle line 240 on a non-interlaced
      odd field, and the PAL equivalents
- [ ] **$4200/$4210 races**: enabling NMI while the flag is set, reading RDNMI
      on the cycle it is raised, IRQ held level-triggered against $4211

## 2. S-CPU

- [x] All 256 opcodes, addressing modes, emulation/native, M/X widths
- [x] Decimal ADC/SBC, block moves, the idle-cycle rules
- [~] Interrupt sequence: correct effect, not yet cycle-by-cycle in which
      cycle pushes what
- [ ] WAI and STP wake behaviour against real interrupt edges
- [ ] ABORT
- [ ] Open bus per bus half, rather than a single MDR

## 3. S-PPU

The largest single gap. Everything below the first item depends on it.

- [ ] **Dot-based rendering.** Registers written mid-scanline must take effect
      from the dot they were written at. Today a line is drawn from the state
      at its start, so every mid-scanline effect is lost.
- [ ] **Offset-per-tile** (modes 2, 4 and 6) — not implemented at all
- [ ] VRAM, CGRAM and OAM access restrictions during active display
- [ ] Sprite evaluation timing, and exact range-over / time-over
- [ ] OAM address reload and priority rotation
- [ ] Interlace, pseudo-hires, overscan, EXTBG
- [ ] Direct colour mode; the remaining colour-math corners
- [ ] Mosaic exactness, including mode 7
- [ ] H/V counter latch on the exact cycle

## 4. APU

- [x] SPC700: all 256 opcodes, three timers, the IPL boot ROM
- [x] S-DSP: BRR, ADSR/GAIN, gaussian interpolation, noise, pitch modulation,
      the FIR echo unit
- [ ] **SPC700 bus-access timing** rather than a flat per-opcode cycle table
- [ ] **DSP as a 32-step pipeline** rather than one lump per sample: KON/KOF
      latch on a 2-sample boundary, ENDX and ENVX read at the right moment,
      echo latency exact
- [ ] The real gaussian table from the chip, replacing the generated one
- [ ] $2140-$2143 access timing against the SPC700's own clock

## 5. Cartridge and coprocessors

- [x] LoROM, HiROM, ExHiROM; interleaved dumps; PAL; battery SRAM
- [ ] **A cartridge device layer**, so a board is ROM + RAM + mapper + devices
      rather than a map-mode enum
- [ ] SA-1 — reuses the existing 65816 core; the work is the memory map, the
      message registers and bus arbitration
- [ ] SuperFX
- [ ] DSP-1/2/3/4, CX4, S-DD1, SPC7110, OBC1, ST010/011, RTC
- [ ] A per-game board database, since headers do not identify boards reliably

## 6. Verification

This is the part that decides whether any of the above converges.

- [x] 65816 assembler, so test ROMs are source in this repository
- [x] Test-ROM harness: real header, real vectors, ordinary boot path
- [x] Deterministic trace, per instruction and per bus access, master-clock
      stamped, with first-difference reporting
- [x] CPU suite: flags, addressing, decimal, RMW, block moves, timing
- [x] Interrupt timing suite
- [ ] **PPU output tests**: per-frame framebuffer hashes, so a rendering change
      that alters output has to be justified
- [ ] **Differential trace against a reference emulator.** The single highest
      -value item left: run the same test ROM here and in bsnes or ares, diff
      the traces, fix the first divergence. Turns "something looks wrong" into
      a cycle number.
- [ ] DMA/HDMA and PPU register timing tests
- [ ] SPC700 and DSP test ROMs
- [ ] CI running the suite on every change

## Order of work

1. Dot-based PPU rendering, with framebuffer-hash tests to hold it in place.
2. Offset-per-tile, which needs the dot pipeline underneath it.
3. DMA and HDMA cycle exactness, with tests.
4. The cartridge device layer, then SA-1 on top of it.
5. Differential tracing against a reference, once there is a reference to hand.
6. The DSP pipeline and SPC700 bus timing.

Coprocessors sit deliberately below the PPU and the timing work: they add
titles, but they do not make the titles that already run any more correct, and
each one is easier to write against a core whose behaviour is pinned by tests.
