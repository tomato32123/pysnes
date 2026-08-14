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

- [x] All 256 opcodes, addressing modes, emulation/native, M/X widths.
      **gilyon's 65C816 test ROM passes all 1610 of its tests**, which it did
      not this morning: it was stopping at test 27, and had been sitting in
      the library recorded as "flat" the whole time, because a batch run that
      presses no buttons never sees past a ROM's first screen.  Five defects
      came out of it, four of them in emulation mode, where several
      instructions stop behaving like the 6502 ones they resemble: the
      pointer wrap of (dp,X) with a non-zero DL, the straight-through pointer
      fetches of [dp] and PEI, the B flag COP pushes, and the whole family of
      stack instructions the 65816 added, which work on all sixteen bits of S
      while they run.  `tools/cputest.py` reads the verdict off the screen
- [x] Decimal ADC/SBC, block moves, the idle-cycle rules
- [x] **When an interrupt is taken**, which is not the same as what it does.
      The 65816 decides a cycle before an instruction ends and acts on the
      decision at the boundary, so: CLI lets an interrupt in one instruction
      late, SEI shuts it out one instruction late, and a DMA finishing inside
      that window hides the lines for a further instruction.  This emulator
      took interrupts at the next boundary, always.
      Sour's `dma_irq_test` measures exactly this and publishes what a console
      answers.  We went from **0 of 14** to **13 of 14**; the fourteenth is
      the high byte of a location the test never initialises, whose low byte
      we match.  `tools/dmairqtest.py` runs it
- [~] Interrupt sequence: which cycle pushes what is still not modelled
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
- [x] **Half-height objects under $2133 bit 1**: an object covers half as many
      scanlines and takes every other row of its own tiles, the field choosing
      which, so the two fields together draw it at its proper shape.  Left
      undone for a year for want of anything that turns the bit on; krom's
      InterlaceRPG turns it on, and goes from 34.65% to 100.00% exact against
      its own screenshot with it implemented.
      One thing about it is unsettled and worth writing down rather than
      quietly deciding.  A note beside Jonas Quinn's `test_oam` tabulates
      object sizes as (OBSEL select, size bit, interlace) and has the
      interlace column change only the two rectangular selects -- 16x32
      becoming 16x16 -- leaving squares and 32x64 alone.  The SNESdev wiki
      says the opposite, that the bit halves every sprite's pixels, and that
      is what is implemented here.  The one demo that turns the bit on uses
      select 6 with the small size, which is the single case where the two
      accounts agree, so the 100% match does not choose between them.  The
      note is unattributed; the wiki is not; the behaviour that matches a
      reference picture stays until something measures the other cases.
      Its `<16x16x2>` annotation does independently corroborate the other
      thing found today, that a 16x32 is two 16x16 squares stacked

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
      The RTC at $4840-$4842 is now there too.  Which cartridges have one is
      in the header -- Tengai Makyou Zero says $F9 and has a clock, Momotarou
      Dentetsu Happy says $F5 and does not -- and it is an Epson part with
      sixteen four-bit registers holding the digits of the time, reached
      through a small state machine: a command saying whether the exchange
      reads or writes, a register number, then the nibbles, which step along
      by themselves.  The time it reports is this machine's.
      The game does not read its clock in the first minute after boot, so
      waiting for it would be a hope rather than a check; the protocol is
      driven against the real cartridge instead, and the digits that come
      back are compared with the host clock, in both twelve- and
      twenty-four-hour form.
      Then the cartridge said the clock was wrong.  Its own check program --
      reachable past the corrupt-backup prompt, which is what "flat" in the
      library run really was -- prints `RTC TIME  NG`, and reading the
      exchange it performs says why: it writes 23:59:59 on 31 December '99
      with weekday 6, runs the clock, stops it and reads back, expecting the
      roll across midnight, month, year and century with the weekday carried
      by one.  Three things were wrong and each was a different kind of
      mistake: the weekday was worked out from the date, which the chip
      never does -- it is a counter a game sets; the clock only moved when a
      read command arrived, so it never moved between the write and the
      read; and midnights were counted by dividing a timestamp by 86400,
      which counts them in UTC rather than where the cartridge is.  The
      cartridge now prints `ALL OK`
- [x] **OBC1.**  Glue logic that builds an object table: a base, a sprite
      index, four bytes a sprite and a two-bit field packed four to a byte,
      with the chip doing the read-mask-shift-write the console would
      otherwise do itself.  It has no program of its own, so nothing about it
      is hidden.  It was written blind until Metal Combat: Falcon's Revenge --
      the only game that has the chip -- arrived; the game now boots, and its
      own use of the chip is the check: the index register moves as it works,
      both bases are used as a double buffer, and the packed area fills with
      coherent size and X-high pairs
- [ ] DSP-1/2/3/4, CX4, ST010/011.  Each is a microcontroller running a
      program mask-ROMed into it, and that dump is not here.  Without it the
      only route is reimplementing what the program does from its documented
      effects, which is a different and much weaker thing than emulating it

## 5a. Speed

- [x] **Measured, and then fixed.**  The core went from 11.4 ms a frame to
      4.6 -- 88 fps to 210 on Super Mario World -- and the play loop from 94.6%
      of frames over the 16.67 ms budget to 15.4%.
      Composition was 63% of everything, measured by removing one stage at a
      time rather than guessed at, and the fix is bsnes's: a table from
      brightness and fifteen-bit colour straight to the finished pixel.  The
      obvious optimisation -- caching the tilemap fetch across the eight pixels
      of a tile -- measured the same and was reverted.
      What made it safe to rewrite the hot path at all was the reference
      pictures: 34 of 35 demos still match pixel for pixel afterwards
- [x] **The display path**: 8.20 ms to draw and present a frame, against
      **0.66** once SDL is handed a texture and left to scale it.  The CPU
      stopped touching two million pixels a frame.  `play.py` falls back to
      the old software scale when there is no renderer -- as on this machine,
      which has no display -- and `--software-scale` forces it, which is how
      the two were measured against each other

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
- [x] **Save states carry the cartridge, and the generator checks itself**:
      every board -- SA-1, S-DD1, SuperFX, SPC7110 -- is serialised, the state
      records which board it came from, and `test_state.py` passes for all
      four.  It failed for all four before, which is how the omission was
      confirmed rather than assumed.
      The lasting part is `check_complete()` in `tools/gen_state.py`: it parses
      each `.pxd` and refuses to generate unless every declared field is either
      saved or excused by name.  A generated serialiser drifts silently -- a
      field added and not registered is simply absent from every state -- and
      that is precisely how the boards went missing.  On its first run it
      found the bus's `timer_irq` unsaved as well
- [x] Open bus suite, and display-mode tests for overscan, hires,
      interlace, EXTBG, direct colour and mosaic
- [x] **SPC700 and DSP test ROMs**: fetched, running, and all passing.  `tools/testroms.py`
      boots a directory of them and captures each verdict.  `spc_smp`,
      `spc_mem_access_times`, `spc_timer` and `spc_dsp6` **all pass**.
      The tests are the apparatus, not the fix; the remaining fix is the DSP
      pipeline above
- [x] **higan's test-ROM collection**: 312 ROMs, byuu's own gathering of what
      the SNES scene has written -- blargg's, krom's, undisbeliever's, neser's,
      Sour's, and more.  `tools/blarggtests.py` runs the self-checking ones and
      reads the verdict off the screen, which for these has to be done by
      pixels: unlike krom's, they build their font in VRAM, so there is no
      character code in the tile map to read.  The word `Passed` is stored as
      the pixels it makes and searched for.
      It found a defect immediately.  `3-test_write_disable` **failed**: the
      SPC700's $F0 TEST register was not implemented at all, so its bits --
      RAM read-only, RAM out of the map, timers off -- did nothing.  Two of
      blargg's tests turn on exactly those, and both pass now.  The register
      also refuses writes while the direct-page flag is set, which is the kind
      of rule only a test ROM ever finds
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
- [x] **krom's PPU demos, against their own screenshots**: 43 demos ship a
      picture of themselves, and `tools/ppucompare.py` compares ours to theirs
      pixel for pixel, with no tolerance.  33 of the 37 comparable ones are
      exact.
      Getting a comparison worth trusting took three things.  The row offset:
      224 rows of reference are scanlines 1 to 224.  The width: a non-hires
      frame is in the 512-wide buffer twice over.  And which references can be
      used at all -- a raw capture only contains colours the SNES can make, so
      a reference with anything else on it has been through field blending or
      an analog capture and cannot be compared exactly.  Six of krom's
      pictures fail that test and are reported as unusable rather than as
      failures.
      It found five defects, none of which any test in this repository could
      have: every background drawn one line too high, the hires sub half-dot
      emitted raw instead of through colour math, that half-dot taking its
      operand from the wrong dot, hires tiles drawn eight half-dots wide
      instead of sixteen, and half-height objects not implemented at all --
      the last of which had been deliberately left undone for want of exactly
      such a reference.  See `docs/remaining.md`
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
