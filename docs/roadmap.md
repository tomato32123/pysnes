# Road to bsnes-level accuracy

This is the checklist.  `remaining.md` is the working brief behind it:
for everything still open, what it is, where in the code it goes, how you
would know you got it right, and what makes it impossible today.

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
- [x] **The scanlines that are not 1364 cycles, and the frames that are not
      262 lines.**  An NTSC machine drops a dot from line 240 of a
      non-interlaced odd field; a PAL machine adds one to line 311 of an
      interlaced odd field.  Each belongs to one region only, and the short
      one used to be applied to both, which cost every PAL game four cycles
      every other frame.  Interlace separately adds a whole scanline to the
      field whose flag in $213F is clear -- 263 lines on NTSC, 313 on PAL --
      which is what makes the two fields comb together.  Five tests, three of
      which discriminate against the old behaviour
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
- [x] **Offset-per-tile** (modes 2, 4 and 6), covered by unit tests.  Three
      titles reach mode 2 and Kirby reaches mode 4; nothing reaches mode 6
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
      with the low bit of each channel from the tilemap's palette field.
      Unit-tested, but no working cartridge in the library switches it on --
      the one title that did turned out to be a broken image reaching it by
      accident, so treat it as unexercised
- [x] **Mosaic**: a counter rather than a division, so a size written
      part-way down the screen lets the current block finish
- [~] H/V counter latch: $2137 and the $4201 latch line both work and
      $213F reports and clears the flag; the single-cycle read race is open
- [x] **Colour math**: forcing the main screen black no longer skips the
      per-layer switch in $2131, so a region asked to stay black does.
      Six tests, one of which discriminates against the old behaviour.
      41 titles use colour math; the forced-black region, like direct colour,
      has no working cartridge behind it
- [ ] Half-height objects under $2133 bit 1

## 4. APU

- [x] SPC700: all 256 opcodes, three timers, the IPL boot ROM
- [x] S-DSP: BRR, ADSR/GAIN, gaussian interpolation, noise, pitch modulation,
      the FIR echo unit
- [~] **SPC700 bus-access timing** rather than a flat per-opcode cycle table.
      Every access -- fetch, read, write -- now moves the SPC700's clock as it
      happens, so a read of a timer or a port sees the machine as of the cycle
      it lands on rather than as of the instruction before.  On top of that,
      the accesses that are not obvious: the byte every one-byte instruction
      reads and discards, and the read a store makes of its destination
      first.  **184 of 256 opcodes now have every cycle where it belongs**,
      against 84 when the clock first started moving per access; the other 72
      carry 90 cycles paid at the end of the instruction.  Two tests hold the
      line -- every opcode still costs what the cycle table says, and the
      count of placed opcodes is a ratchet -- so the rest can be done a few
      opcodes at a time.
      Three of the four APU test ROMs fail on this one thing, which makes it
      the next piece of work rather than the least appealing of three
- [x] The timers' first stage is a scaler that free-runs whether or not the
      timer is enabled; an enable resets the divisor and the output counter
      but not it.  All three used to be reset together, which put every timer
      in phase with whenever it was switched on
- [ ] **DSP as a 32-step pipeline** rather than one lump per sample: KON/KOF
      latch on a 2-sample boundary, ENDX and ENVX read at the right moment,
      echo latency exact
- [ ] The real gaussian table from the chip, replacing the generated one
- [ ] $2140-$2143 access timing against the SPC700's own clock

## 5. Cartridge and coprocessors

- [x] LoROM, HiROM, ExHiROM; interleaved dumps; PAL; battery SRAM
- [x] **The header checksum over the ROM as the console addresses it**, not
      over the file: a cartridge whose size is not a power of two mirrors its
      tail to fill the window, so those bytes are counted more than once.
      Folding each address through the same rule the bus uses took the local
      library from 19 mismatches to 7, and every one of the 7 left is a hack
      or a translation whose header was never updated
- [x] **A cartridge board layer**: the bus asks the board what is at each
      page, and asks it again per access for the pages a board keeps for a
      chip of its own.  Anything in $2000-$5FFF the console does not decode
      goes out to the cartridge, which is where an SA-1's registers live
- [x] **A board database** (`snes/boards.py`): the header's chipset byte as
      a first guess, a CRC-32 keyed override as the last word.  A chip with
      no board says so rather than passing as an ordinary cartridge
- [~] **SA-1**: the second 65816 runs, with the Super MMC bank switcher,
      I-RAM, BW-RAM and both windows, the message registers and interrupts
      each way, both processors' own and borrowed vectors, multiply, divide
      and accumulate, the variable-length bit reader, plain DMA, the timers
      and both kinds of character-conversion DMA.
      Two caveats.  The timers and character conversion are written from the
      documented behaviour and nothing in the local library turns them on, so
      they are unverified.  And there is no bus arbitration: the SA-1 catches
      up to the console rather than the two sharing a scheduler, so a game
      that depends on which of them wins a contended cycle would not see it
- [ ] SuperFX
- [x] **S-DD1**: mapper and decompressor.  A 32 Mbit S-DD1 cartridge fits no
      standard map -- banks $C0-$FF are four 1 MB slots chosen by $4804-$4807
      -- and Street Fighter Zero 2 jumps into that window three instructions
      after reset, so the mapper alone is the difference between a black
      screen and a running game.  On top of it, the ABS decompressor: a bit
      reader, eight Golomb decoders, a 33-state probability ladder per
      context, a context model over the bits already decoded in the same
      bitplane, and the output logic for the four tile arrangements.
      Which transfers the chip takes over is settled by measurement: a
      channel armed in both $4800 and $4801 *and* reading from the
      cartridge's own banks, which over 600 frames is two transfers out of
      496.  The arming masks alone are not enough -- the game leaves them set
      and does its sprite DMA out of WRAM on the same channel.
      Street Fighter Zero 2 draws its Capcom logo and its title screen
- [ ] SPC7110, OBC1, RTC.  Glue logic and decompressors with documented
      behaviour and no firmware of their own, so they can be written; nothing
      in the local library needs them, so they would be written blind
- [ ] DSP-1/2/3/4, CX4, ST010/011.  Each is a microcontroller running a
      program mask-ROMed into it, and that dump is not here.  Without it the
      only route is reimplementing what the program does from its documented
      effects, which is a different and much weaker thing than emulating it

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
- [~] **Differential trace.** `tools/difftrace.py` records a trace, compares
      two, and reports the first divergence with the cycle it happened on and
      the instructions around it; `--fields` lets a reference log that is
      missing a column still be compared on the rest.  Four short programs
      have their traces committed under `tests/golden/` and `test_trace.py`
      checks them, so a cycle that moves is a diff rather than a game that
      stops working three weeks later.
      What is missing is a reference: no bsnes or ares on this machine, so
      the comparison that would say the emulator is *right* rather than
      *unchanged* has not been run
- [x] DMA and HDMA timing tests; PPU register timing still open
- [x] Open bus suite, and display-mode tests for overscan, hires,
      interlace, EXTBG, direct colour and mosaic
- [~] **SPC700 and DSP test ROMs**: fetched and running.  `tools/testroms.py`
      boots a directory of them and captures each verdict.  All four fail
      today -- `spc_smp`, `spc_mem_access_times`, `spc_timer` and `spc_dsp6`
      -- which is what the three open APU items predict.  The tests are the
      apparatus, not the fix; the fixes are section 4
- [x] **CI**: the suite runs on every push, on Linux and Windows.  The
      ROM-dependent modules skip themselves rather than fail, since no ROM
      belongs in the repository and the rest builds its own test images

## Order of work

1. ~~Dot-based PPU rendering~~ done.
2. ~~Offset-per-tile~~ done.
3. ~~DMA and HDMA exactness~~ done.
4. ~~The display modes: overscan, hires, interlace, EXTBG, direct colour~~ done.
5. ~~The cartridge board layer, then SA-1 on top of it~~ done.
6. ~~The tooling for differential tracing~~ done; the comparison itself
   waits on a reference emulator being available.
7. The DSP pipeline and SPC700 bus timing.
8. SA-1 bus arbitration, and SuperFX.

Coprocessors sit deliberately below the PPU and the timing work: they add
titles, but they do not make the titles that already run any more correct, and
each one is easier to write against a core whose behaviour is pinned by tests.
