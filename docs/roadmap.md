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
- [x] **DMA cycle exactness**: eight cycles per byte, eight to start, eight
      per channel, plus the wait for the DMA clock edge; asserted by tests
- [x] **HDMA init and reload**: the init pass at the top of the frame, the
      transfer-then-advance order, repeat and non-repeat counts, indirect
      reloads, and a mid-frame enable waiting for the next frame
- [x] **DRAM refresh**: 40 cycles stolen once per scanline at dot 134
- [x] **Short scanline**: line 240 of a non-interlaced odd field is 1360
      cycles; the PAL long line is still open
- [~] **$4200/$4210**: enabling NMI while the flag is set fires at once, and
      the flag clears both on read and at the top of the frame; the
      single-cycle read race is still open

## 2. S-CPU

- [x] All 256 opcodes, addressing modes, emulation/native, M/X widths
- [x] Decimal ADC/SBC, block moves, the idle-cycle rules
- [~] Interrupt sequence: correct effect, not yet cycle-by-cycle in which
      cycle pushes what
- [x] **WAI and STP**: WAI wakes on an NMI and takes it, wakes on a masked
      IRQ without taking it, and STP stays halted until reset
- [x] **Open bus**: three latches, not one -- the CPU's, PPU1's and PPU2's.
      A write-only PPU register reads back PPU1's last value rather than the
      CPU's, and the two chips report different versions, which is what makes
      them distinguishable.  Eight tests in `test_openbus.py`
- [n/a] ABORT.  The pin is not connected on the SNES, so the vector is
      unreachable and there is nothing to model

## 3. S-PPU

The largest single gap. Everything below the first item depends on it.

- [x] **Dot-based rendering**: a row is drawn in spans, caught up before every
      write to $2100-$213F, so a mid-scanline change takes effect from its dot
- [x] **Offset-per-tile** (modes 2, 4 and 6), covered by unit tests; no title
      in the local library reaches those modes during boot, so it has not
      been seen against real software yet
- [x] VRAM, CGRAM and OAM access restrictions during active display
      (OAM approximated: the write is dropped rather than redirected to
      the address sprite evaluation holds, which needs a per-dot evaluator)
- [x] Sprite evaluation in two passes: 32 sprites per line and 34 tiles,
      with range-over and time-over reported per frame
- [~] OAM priority rotation moves the first sprite of the scan; the
      address reload's own timing is not modelled
- [x] **Overscan**: 239 lines instead of 224, sampled per line, moving
      V-blank and the NMI with it
- [x] **Hires**: the framebuffer is 512x478 and every dot emits two pixels.
      Pseudo-hires fills the left one from the sub screen; modes 5 and 6
      give BG1 and BG2 a value per half-dot, with the main screen taking the
      odd ones and the sub screen the even ones
- [x] **Interlace**: each field draws every other row from every other
      source row, leaving the other field's rows alone
- [x] **EXTBG**: mode 7's pixel feeds BG1 whole and BG2 as seven bits plus a
      priority, so BG2 straddles BG1
- [x] **Direct colour**: an 8bpp pixel becomes a colour rather than an index,
      with the low bit of each channel from the tilemap's palette field
- [x] **Mosaic**: a counter rather than a division, so a size written
      part-way down the screen lets the current block finish
- [~] H/V counter latch: $2137 and the $4201 latch line both work and
      $213F reports and clears the flag; the single-cycle read race is open
- [ ] The remaining colour-math corners
- [ ] Half-height objects under $2133 bit 1

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
- [x] **PPU output tests**: pixel-level assertions on backdrop, tiles, scroll,
      brightness and the mid-scanline split, plus a scene hash
- [ ] **Differential trace against a reference emulator.** The single highest
      -value item left: run the same test ROM here and in bsnes or ares, diff
      the traces, fix the first divergence. Turns "something looks wrong" into
      a cycle number.
- [x] DMA and HDMA timing tests; PPU register timing still open
- [x] Open bus suite, and display-mode tests for overscan, hires,
      interlace, EXTBG, direct colour and mosaic
- [ ] SPC700 and DSP test ROMs
- [x] **CI**: the suite runs on every push, on Linux and Windows.  The
      ROM-dependent modules skip themselves rather than fail, since no ROM
      belongs in the repository and the rest builds its own test images

## Order of work

1. ~~Dot-based PPU rendering~~ done.
2. ~~Offset-per-tile~~ done.
3. ~~DMA and HDMA exactness~~ done.
4. ~~The display modes: overscan, hires, interlace, EXTBG, direct colour~~ done.
5. The DSP pipeline and SPC700 bus timing.
6. The cartridge device layer, then SA-1 on top of it.
7. Differential tracing against a reference, once there is a reference to hand.

Coprocessors sit deliberately below the PPU and the timing work: they add
titles, but they do not make the titles that already run any more correct, and
each one is easier to write against a core whose behaviour is pinned by tests.
