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
- [x] **SPC700 bus-access timing** rather than a flat per-opcode cycle table.
      Every access -- fetch, read, write -- moves the SPC700's clock as it
      happens, so a read of a timer or a port sees the machine as of the cycle
      it lands on rather than as of the instruction before.  On top of that,
      the accesses that are not obvious: the byte every one-byte instruction
      reads and discards, and the read a store makes of its destination first.
      **All 256 opcodes have every cycle where it belongs**, against 84 when
      the clock first started moving per access.  Two tests hold the line --
      every opcode still costs what the cycle table says, and the count of
      placed opcodes is a ratchet at 256.
      The order is pinned as well: `test_apu_cycles.py` holds the expected run
      of reads, writes and idles for all 256 and compares it against what
      reaches the bus.
      `spc_timer`, `spc_mem_access_times` and `spc_smp` all **pass** -- the
      first hardware test ROMs this emulator has passed, and `spc_smp` in all
      sixteen of its sections.  Three plain bugs fell out on the way: `DBNZ Y`
      ran eight cycles when taken against hardware's six, because the table
      already held the taken cost and the branch added it again; `INCW`/`DECW`
      read both bytes before writing either, where the chip writes the low
      byte back before it reads the high one; and `$F0`, `$F1` and the three
      timer targets are write-only registers that were handing back what had
      been written to them instead of zero
- [x] The timers' first stage is a scaler that free-runs whether or not the
      timer is enabled; an enable resets the divisor and the output counter
      but not it.  All three used to be reset together, which put every timer
      in phase with whenever it was switched on
- [x] **DSP as a 32-step pipeline** rather than one lump per sample.  Written
      as the chip's own 32 steps, with eight voices each at a different one at
      any moment.  KON and KOFF are acted on every other sample; ENDX, OUTX
      and ENVX are written back from buffers; ESA and EDL are latched; the
      echo's FIR halves on the way in and truncates between its last two taps.
      It also turned up that the audio was 6 dB quiet -- the decoder's 15-bit
      sample is carried doubled, and both this and the independent decoder in
      `test_dsp.py` kept the undoubled value, so they agreed with each other
      and neither was right.  Faster as well, at 99 fps against 81.
      `spc_dsp6` **passes**, all thirteen sections, having reached three when
      the work started
- [x] **The real gaussian table from the chip**, replacing the generated one.
      The generated one had its width solved to put the peak on the real
      table's 1305 and each group of four taps normalised to sum to exactly
      2048.  The real table's groups sum to 2047, 2048 or 2049, and that one
      unit was the whole of the last difference against the reference: a voice
      whose samples are small came out a couple of units off.  Inaudible, and
      exactly what a chip comparing itself against hardware notices
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
- [~] **SuperFX**: the GSU runs.  Its own instruction set across the ALT1,
      ALT2 and ALT3 prefixes with the FROM/TO/WITH register prefixes, the
      512-byte instruction cache, the buffered ROM and RAM readers, the plot
      unit with its pixel cache and `rpix` read-back, the screen modes, and
      the interrupt on `stop`.
      The part that is easy to get wrong and hard to notice is what the
      *console* sees: while the chip is running the cartridge hands it the
      ROM, and a console read gets a sixteen-byte vector table instead --
      including when that read is the console fetching its own instructions.
      A game's wait loop therefore cannot live in ROM, and Star Fox's does
      not: it runs from work RAM.
      Star Fox draws its intro polygons and its title screen, and the
      instruction set now answers to an outside authority: krom's 31 GSU
      instruction tests all pass (see Verification below).
      What they do not cover is time.  The chip catches up to the console
      rather than the two sharing a scheduler, so cycles are counted but
      contention is not, and the stray black rectangles in Star Fox's intro
      are most likely that
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
- [x] **SPC7110**: four devices in one package -- the decompression unit, a
      data port that walks the data ROM, a 16x16 multiplier and 32/16
      divider, and the memory controller that decides which megabyte of the
      data ROM each quarter of the address space shows.  A cartridge with
      this chip carries two ROMs, and the second one the console cannot
      address at all: every byte of it arrives through a port.
      The compression is a binary arithmetic coder with a context model over
      the pixels already decoded and a move-to-front colour list; its 53-state
      probability ladder is transcribed hardware design data, from neviksti's
      and talarubi's published implementation, not reasoned out here.
      Verified by the cartridge itself.  Momotarou Dentetsu Happy carries an
      SPC7110 CHECK PROGRAM in its ROM and runs it whenever the save RAM does
      not hold "SPC7110 CHECK OK"; `tools/spc7110check.py` drives it and reads
      the verdict out of the program's own result table.  All twelve of its
      tests pass, it writes the signature, and the game boots to its title
      screen.
      Missing: the RTC at $4840-$4842, which only Far East of Eden Zero has
      and which nothing here can check
- [ ] OBC1.  Glue logic with documented behaviour and no firmware of its own,
      so it can be written; nothing in the local library needs it, so it would
      be written blind
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
- [x] **SPC700 and DSP test ROMs**: fetched, running, and all passing.  `tools/testroms.py`
      boots a directory of them and captures each verdict.  `spc_smp`,
      `spc_mem_access_times`, `spc_timer` and `spc_dsp6` **all pass**.
      The tests are the apparatus, not the fix; the remaining fix is the DSP
      pipeline above
- [x] **The SPC7110's own check program**: Momotarou Dentetsu Happy carries
      one in its ROM and boots into it whenever the save RAM does not say the
      chip has been checked.  `tools/spc7110check.py` runs both its modes and
      reads the verdict from the program's own result table rather than from
      the screen.  It passes -- and on the way it found a bug of ours that
      had nothing to do with the SPC7110: an unwritten save RAM reads $FF, not
      $00.  A second hardware-authored oracle, arrived by accident, which is
      the argument for item 8 below made twice
- [x] **krom's instruction test ROMs**: 66 of them, and all 66 pass.  One ROM
      per instruction -- 23 for the 65816, 7 for the SPC700, 31 for the GSU,
      5 for the bank mapping -- each walking every addressing mode and
      checking the result and all four flags in 8- and 16-bit, binary and
      decimal.  `tools/kromtests.py` boots them and reads each verdict out of
      VRAM: the font is loaded so that tile number equals character code, so
      the screen is text rather than pixels, and a failing test prints FAIL
      and then branches to itself, so nothing can be missed by sampling.
      The harness was checked the only way a harness can be: by breaking the
      emulator on purpose.  One bit of ADC's carry (`> 0xFF` to `> 0x100`)
      turns CPUADC red and names the addressing mode and the row.
      What this is *not* is a timing authority.  These check what an
      instruction computes, not when -- so item 8 below is narrowed rather
      than answered
- [x] **CI**: the suite runs on every push, on Linux and Windows.  The
      ROM-dependent modules skip themselves rather than fail, since no ROM
      belongs in the repository and the rest builds its own test images

## Order of work

1. ~~Dot-based PPU rendering~~ done.
2. ~~Offset-per-tile~~ done.
3. ~~DMA and HDMA exactness~~ done.
4. ~~The display modes: overscan, hires, interlace, EXTBG, direct colour~~ done.
5. ~~The cartridge board layer, then SA-1 on top of it~~ done.
6. ~~The tooling for differential tracing~~ done.
7. ~~The DSP pipeline and SPC700 bus timing~~ done, and every hardware test
   ROM on this machine passes as a result.
8. **Find the CPU and PPU an external authority.**  Half done, and the half
   that is done cost an afternoon.  krom's 66 instruction tests are here and
   all pass, which settles *what* the 65816, the SPC700 and the GSU compute --
   every addressing mode, every flag, both widths, decimal and binary.
   What is still unanswered is *when*.  Nothing here checks a cycle count, an
   interrupt's exact arrival, or a PPU register written mid-scanline, and
   those are where the APU's nine defects lived: a cycle table two cycles out,
   a read-modify-write in the wrong order, registers handing back what was
   written to them, a timer in the wrong phase, key-on a sample late, six
   decibels of missing volume, and an interpolation table a unit wide.  The
   remaining ways in: krom's PPU demos have reference screenshots to compare
   against, and `tools/difftrace.py` has been waiting for a reference emulator
   since it was written.
9. SA-1 bus arbitration, and the SuperFX's contention -- both are the same
   problem, and both now have a game to answer to.
10. ~~SPC7110~~ done, and its cartridge brought its own test program with it.

Coprocessors sit deliberately below the PPU and the timing work: they add
titles, but they do not make the titles that already run any more correct, and
each one is easier to write against a core whose behaviour is pinned by tests.
