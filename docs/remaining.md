# What is left, and what it would take

`roadmap.md` is the checklist. This is the working brief behind it: for each
thing still open, what it actually is, where in the code it goes, how you
would know you got it right, and what — if anything — makes it impossible
today. Written so it can be picked up cold.

As of this writing the 68-ROM local library has **no unexplained failure**.
Four titles do not draw a game, and each is accounted for: two are defective
ROM images (proved defective, not assumed so), one wants a coprocessor whose
firmware is not here, and one is a blank cartridge correctly booting the
check program its own ROM carries. Everything else renders.

That sentence is worth reading sceptically, because it was wrong twice this
week in opposite directions. Rudra no Hihou was written up here as a defect
and is not one — its opening simply takes longer than the tool allowed. And
five defects were sitting in the PPU while every test in this repository
passed. Neither the pass list nor the fail list is evidence on its own; what
the emulator is checked *against* is.

---

## First, the thing that shapes everything else

**There is no reference emulator on this machine.** No bsnes, no ares, no
Mesen. That single absence is why six items are "partial" rather than done,
and it is worth understanding what it costs before reading the rest.

**The largest of them turned out to be a download away.** krom's per-instruction
test ROMs — 66 of them, covering the 65816, the SPC700 and the GSU — are now
here and all pass. They settle what every instruction computes in every
addressing mode, with every flag, in both widths and both arithmetic modes.
They say nothing about *when*, which is where the APU's nine defects lived, so
what follows is still true of timing. But "no external authority" was only
ever true of timing, and it took an afternoon to find that out.

**And the PPU got one in the same afternoon.** krom's demos ship a screenshot
each, and comparing against them pixel for pixel found three defects in the
renderer — one of them in every frame this emulator has ever drawn. All three
are described under "What the reference pictures found" below. The tests in
this repository passed throughout, before and after, because they were written
from the same understanding as the code: exactly the failure mode this section
was written to warn about, demonstrated on the section that warned about it.

There are now four things that partly substitute for a reference, and it is
worth knowing which parts. blargg's SPC test ROMs are here (see item 10), and
`tools/dspdiff.py` runs the DSP against blargg's own implementation sample by
sample: real external authority, but only over the APU. The third arrived by
accident and covers one chip — Momotarou Dentetsu Happy carries the
manufacturer's own SPC7110 check program in its ROM (item 7), and it audits
the chip's registers, its arithmetic and its save RAM. Everything to do with
the CPU's and the PPU's timing is still checked against nothing but this
project's own reading of the documentation.

That third one is worth a second look by anyone deciding what to do next. It
was not sought, it cost nothing to run, and it immediately found a defect
outside the chip it tests. It is worth asking which *other* cartridges in the
library carry a self-test — Hudson put one in this cartridge, and Hudson made
several of the others.

That asymmetry is now measurable rather than theoretical. An external
authority arrived for one subsystem and, within a day, found seven defects in
it — in code the checklist called done. The parts of this emulator with no
such authority have exactly the epistemic standing the APU had the morning
before, which is the strongest argument in this file for what to do next.

A test says a feature behaves the way the test author believed it should. A
reference says it behaves the way the hardware does. Everything below that
is marked *unverified* is code written from documentation, passing tests
written from the same documentation — which means a misreading produces a
green suite.

`tools/difftrace.py` is built and waiting. The moment a reference is
available:

```
python tools/difftrace.py record            # our traces
# dump the same test ROMs from bsnes/ares into the same format
python tools/difftrace.py diff ours.trace theirs.trace
```

It reports the first divergence as a master-clock cycle number, which field
differs, and the instructions either side. `--fields` drops columns a foreign
log does not carry. That turns "the picture looks wrong" into a place to
look, and it is the single highest-leverage thing that could be added to this
project from outside.

---

## Second, what no cartridge has ever exercised

`tools/featureprobe.py` runs the whole library and records which parts of the
chip anything actually switches on. Run over 66 ROMs for 900 frames each:

| feature | titles using it |
|---|---|
| offset-per-tile (mode 2) | 3 — Chrono Trigger, The Simpsons, … |
| offset-per-tile (mode 4) | 1 — Kirby Super Deluxe |
| hires (mode 5) | 2 — Donkey Kong Country, DBZ Super Butouden 3 |
| overscan | 7 |
| direct colour | 1 — `Mix.smc` |
| main screen forced black | 1 — `Mix.smc` |
| mosaic | 2 |
| colour math | 41 |
| sub screen as operand | 36 |
| counter latch | 21 |
| SA-1 arithmetic | 4 |
| SA-1 variable-length reader | 3 |
| **mode 6 (hires + offset-per-tile)** | **0** |
| **interlace** | **0** |
| **object interlace** | **0** |
| **pseudo-hires** | **0** |
| **EXTBG** | **0** |
| **SA-1 timers** | **0** |
| **SA-1 character conversion, both types** | **0** |
| **SA-1 DMA** | **0** |

The nine in bold are implemented, tested, and have never been run by real
software. Their correctness rests entirely on the documentation having been
read right. That is not the same as being wrong — but it is the class of
thing that quietly stays wrong for years, and it should be the first target
whenever a reference or a wider ROM set becomes available.

Note the two entries against `Mix.smc`. That was written down as a lead, on
the grounds that the only title using direct colour or the forced-black
region was also one of the three rendering nothing. The lead is now closed,
and not in the direction hoped for: `Mix.smc` turns out to be a defective ROM
image (below), so the settings it reaches are ones a crashed program wandered
into rather than ones a game meant. Read the table with those two rows struck
out: **direct colour and the forced-black region have no working cartridge
behind them either**, which puts them in the same class as the nine in bold.

---

### Re-run over a bigger library, and unchanged where it matters

The table above was taken over 66 cartridges.  The library is 74 now, and
the probe was run again: **the nine features nothing exercises are still
the same nine**.  Not one of mode 6, interlace, object interlace,
pseudo-hires, EXTBG, the SA-1's timers, either of its character
conversions or its DMA has been switched on by any real software here.

What did move: colour math 41 to 46 titles, the sub screen as an operand
36 to 38, overscan 7 to 8, and sprite time-over now has eight titles
behind it.  One entry changed in kind rather than degree -- the forced
black main screen had only `Mix.smc` behind it, which is a defective
image wandering into settings no game chose, and now has Exhaust Heat II
as well.  That is its first honest witness.  Direct colour and mosaic
still rest mainly on `Mix.smc`, so they stay in the unexercised class in
everything but name.

The value of this run is in what did not change.  Nine features are
implemented and tested, and their tests were written from the same
reading of the documentation as the code.  Today's two interlace defects
-- a rectangular sprite's V-flip and the height of a mosaic block on an
interlaced hires screen -- were found by a reference picture while every
test here passed, which is exactly the failure this list predicts for the
other nine.

## What the reference pictures found

`tools/ppucompare.py` runs krom's PPU demos and compares our output to the
screenshot each ships, pixel for pixel. Three defects came out of it, and it
is worth reading them as a set: none was a crash, none broke a game visibly,
and every test in this repository passed with all three present.

**Every background was drawn one line too high.** Scanline 0 is not displayed,
so the first row on screen is scanline 1 — and a layer's vertical source is
that scanline, not the zero-based row it lands on. Games write `$FFFF` to
BGnVOFS when they want the top of the map at the top of the screen, and that
convention is exactly why this can be wrong for years without looking wrong:
every layer moves together, by one line, at the very top of the screen. Four
static demos independently said +1, and bsnes samples `vcounter()`. The fix is
one line in `begin_line`; the scene hash in `test_ppu.py` did not change,
because the tests scroll by -1 like a real game and the two cancel.

**The hires sub half-dot was emitted raw.** In hires the left half of every dot
comes from the sub screen, and this emulator sent it straight to the
framebuffer. Hardware puts it through the same output stage as the main half,
with the two screens exchanged: the sub colour is what colour math is applied
*to*, and the operand is the main colour or the fixed colour. Only the even
columns were wrong, only in hires, and only when a game puts different pictures
on the two screens — which is precisely what the "HiColor" demos do, and what
they exist to demonstrate.

**And that half-dot is a dot behind.** The output stage builds the left half
before it has looked at the dot's own main screen, so the operand and all three
colour-math switches come from the dot to its left. This is visible as a single
colour level here and there along a row — it took a photograph to see it, and
`lenna64PerTileRowHiRes` went from 76.68% to 99.80% exact when it was modelled.
The remaining 0.2% was the first dot of each line, which has nothing to its
left: bsnes emits black there and says in a comment that the value is not
confirmed on hardware; the references show the sub screen untouched, which is
what is implemented and what takes those demos to 100.00%.

**A hires tile is always sixteen half-dots wide.** $2105's size bit chooses the
height in modes 5 and 6, not the width, and this emulator used it for both. An
8x8 tile in mode 5 was therefore drawn eight half-dots wide, which reads the
tilemap at twice the rate and puts the wrong half of every character on the
screen. `InterlaceRPG` went from 34.65% to 98.77% and `MosaicMode5` from
68.17% to 90.30%; `InterlaceFont` — whose whole picture is in its top 72 rows,
so its earlier "95%" was black agreeing with black — went from letters made of
fragments of other letters to letters. Two mode 5 tests in `test_ppu.py`
passed before and after, because what they assert is true either way.

**Objects can be half height.** `InterlaceRPG`'s remaining difference was a
single 40x112 rectangle, which is a sprite-shaped hole, and the demo turns on
`$2133` bit 1. Implementing it took that demo to 100.00% exact — see item 5
below, which had been waiting for exactly this.

**`InterlaceFont` was not a difference at all — its reference is a rescale.**
Every row we draw appears in the reference *exactly*, all 512 pixels of it, in
order, but spread out: the offset grows from +9 to +10 to +11, at a slope of
28/27, which is 448/432. The reference is a 432-row capture stretched into a
448-row file, and 437 of its 448 rows are ours verbatim — the missing eleven
being the rows the stretch duplicated. A rendering difference changes pixels;
it does not reproduce our exact rows in order at a different spacing.

That reasoning is now in `tools/ppucompare.py` rather than in this file: a
demo that fails the pixel comparison is aligned against our output row by row,
and a reference whose rows are 95% ours, in order, is reported as a rescale
instead of a failure. It needs no guess about which scaler was used.

*Still open, from the same comparison*: `MosaicMode5`, at 96.26% — and this
one is real. 280 of its 448 rows are ours verbatim, so it is not a rescale,
and the difference is in a band from row 48 to row 415. Mosaic in mode 5 with
interlace is the last untested corner of the renderer. Note that the
screenshot is at mosaic size 7, not the maximum: the comparison was measuring
the wrong state until `drive` was changed to watch the register rather than
count button presses, which is worth remembering for any other demo the pad
steers. Six more
references cannot be used at all, because they contain colours the SNES cannot
produce; `RedSpace9BitHDMA` is the interesting one of those. It drives
brightness through HDMA a line at a time, our output matches it exactly on
every full-brightness line, and on the dimmed lines no arithmetic rule
reproduces the reference — the closest of eight candidates gets 170 of 224
lines. That is a capture of an analog dimming curve, not a rule to copy.

*One change here rests on bsnes alone*: in hires the horizontal scroll counts
dots and the layer is drawn in half-dots, so the scroll moves the layer twice
as far. bsnes does this explicitly; no demo here scrolls a hires layer far
enough to demonstrate it.

## The untouched items

### 1. SPC700 bus-access timing — done, and it earned the project its first
### passing hardware test

*Where*: `snes/apu.pyx`, the opcode dispatch.

**Done**: every access moves the clock as it happens. The SPC700 spends a
cycle per bus access, and `fetch`, `read` and `write` now charge it, so a read
of a timer or of `$2140` sees the machine as of the cycle it lands on. It used
to see the machine as of *before the instruction started*, whatever cycle the
read was really on, because the whole opcode was charged from a table after
it had finished.

**Also done**: the accesses an instruction makes that are not obviously part
of it, and most of the idle placement.

- Every one-byte instruction reads the byte after itself and throws it away.
  The SPC700 fetches it before it knows it does not need it, and the read is a
  real bus cycle. Seventy-six opcodes, kept as a table rather than a line in
  each branch.
- A store reads its destination first and discards the byte. The cycle was
  always charged; that it is a *bus access* was not modelled, and that is
  most of what `mem_access_times` is looking at. The two indirect-increment
  forms are the documented exceptions — one spends the cycle idle instead.
- An indexed address costs a cycle of its own between the operand fetch and
  the data access. Branches spend their two extra cycles before the jump
  rather than after the instruction. Pushes idle last, pulls idle first.
  Calls, returns, `MUL`, `DIV` and `XCN` spend theirs where the reference
  says.

**All 256 opcodes now have every cycle where it belongs**, against 84 when
the accesses first started moving the clock. Nothing is paid at the end of an
instruction any more.

**`spc_timer.sfc` passes.** That is the first hardware test ROM this
emulator has ever passed, and what it was failing on was exactly this: a read
of a timer against a write to it, which cannot come out right while the
instruction's cycles are charged after it has finished.

The work also turned up a plain bug in the cycle table. `DBNZ Y` was listed
as six cycles and then had the two cycles for a taken branch added on top, so
it ran eight when hardware takes six. Four and six are its real costs. That
had been there since the table was written and nothing had noticed, because
nothing was in a position to.

Two tests keep this honest. Every opcode must cost exactly what the cycle
table says, so moving an idle around cannot silently change an instruction's
length; and the count of fully placed opcodes is a ratchet at 256, so it
cannot go back down while someone works on something else.

The cycle-by-cycle account came from bsnes's SPC700 core, which writes each
addressing mode as an explicit sequence of reads, writes and idles. Deriving
it by reasoning was not on: the dummy read before a store, and the two
instructions that skip it and idle instead, are not the sort of thing that
can be worked out from a cycle count.

**The order is right too, and that is now pinned.** `tests/test_apu_cycles.py`
holds the expected run of reads, writes and idles for every one of the 256
opcodes, transcribed from the same reference, and compares it against what the
emulator actually puts on the bus. Writing it found the last ordering bug:
`INCW` and `DECW` were reading both bytes and then writing both, where the
chip reads the low byte, writes it back, and only then reads the high one.
A program watching the address bus can tell those apart.

**And the last difference was not timing at all.** With counts and order
both matching, `spc_mem_access_times` still failed, and the remaining
candidate was the value an access returns rather than the cycle it lands on.
`$F0`, `$F1` and the three timer targets are write-only: they can be written
and they read back zero. This emulator handed back whatever had been written
to them. A read is an access, and that one returned the wrong byte.

**All four test ROMs pass.** Every section of every one: the SPC700's
instructions and their timing, the timers, the whole DSP including the step
each voice register is written back on.

Speed: 81 fps on Super Mario World against 92 before and 60 for real time.
The extra bus accesses cost about a tenth of the frame rate, which is a fair
price for a hardware test that now passes.

This was written down as one of three open APU items and as the least
appealing of them, on the grounds that it is only observable through
`$2140-$2143`. The test ROMs say otherwise. It is what
`spc_mem_access_times` tests directly, what `spc_smp` turns red on after
passing every instruction-behaviour section, and what `spc_timer` is really
asking about when it compares a read against a write. Three of the four
failures are this one thing, so it is now the highest-value item in the file
by some distance.

*How you would know*: those three ROMs stop saying Failed 02. The CPU already
charges per access (`snes/cpu.pyx`), so the shape to copy is in the tree.

*Risk*: the audio currently sounds right and was confirmed so by ear. Any
change here can break that silently. Do it with the DSP output hashed before
and after.

### 2. DSP as a 32-step pipeline — done

The chip does not compute a sample and then move on. It walks 32 steps, and at
any moment eight voices are each at a different one: while voice 0 is being
written out, voice 2 is reading its BRR header and voice 5 is having its
envelope run. That is now what this does, step for step, and `spc_dsp6` goes
from three passing sections to twelve.

Almost everything a per-sample lump gets wrong follows from the steps not
existing. A register read at step 21 and used at step 30 does not see a write
that landed at step 25. KON is acted on every *other* sample, so a program can
write and clear it between two samples and have it seen once or not at all.
ENDX, OUTX and ENVX are written back from buffers, so a write one or two steps
before the pipeline gets there is overwritten and a write after it is not.
None of that can be said at all without the steps.

**It also turned out the audio was 6 dB quiet, and had been all along.** The
decoder's output is a 15-bit sample carried in the top fifteen bits of
sixteen — doubled, in other words — and both this emulator and the
independent decoder in `test_dsp.py` kept the 15-bit value instead. They
agreed with each other, so nothing complained. They are the same arithmetic:
the filter coefficients in the two differ by exactly that factor of two, one
shift at a time. Doubling it is what lets a full-scale sample reach full
scale at the DAC rather than stopping half way, and the test now checks
against that convention rather than against the emulator's old habit.

`test_dsp.py` is worth keeping in mind here: it decodes BRR independently, in
plain Python, and compares by correlation rather than by value. That is why it
survived the rewrite and still says 0.9896 — it was measuring the shape, which
was right, and it caught the scale the moment its own reference was corrected.

Faster, too, at 99 fps on Super Mario World against 81 before: the steps do
less work between them than the lump did in one go.

**How the last of it was found** is worth recording, because guessing had run
out.

`tools/dspdiff.py` drives this DSP and blargg's own through the same script of
register writes and reports the first sample where they disagree, reading both
through ENVX, OUTX and ENDX — the registers a program can see. It is the
differential comparison the top of this file has been asking for since it was
written, and it exists for the DSP because the reference builds in a few
seconds and needs nothing but a C++ compiler. `tools/dspprobe.cpp` is the
reference half; the reference itself is not in this repository.

It found two things. The chip comes out of reset **half way through a KON
pair**, and this started at the other half, so every key-on was acted on one
sample late. And once the internals were dumped side by side and found
identical — same kon_delay, same interp_pos, same buffer, same envelope, every
sample — the only thing left that could differ was the interpolation
coefficients. It was the gaussian table (item 3).

`spc_dsp6` passes all thirteen sections, from three when this started.

### 3. The real gaussian table — done

*Where*: `snes/apu.pyx`, `GAUSS`.

It used to be generated: a gaussian with its width solved to put the peak on
the real table's 1305, and each group of four taps normalised to sum to
exactly 2048. That was close enough to sound right and not close enough to be
right. The real table's groups sum to 2047, 2048 or 2049, and that one unit
was the whole of the last difference against blargg's DSP — a voice playing
small samples came out a couple of units off, which is inaudible and is
precisely what a differential comparison sees.

This file used to say the table could not be done from reasoning and had to be
copied from a dump or another emulator's source. That was right, and that is
what happened. It is transcribed from blargg's S-DSP.

### 4. `$2140-$2143` access timing

*Where*: `snes/bus.pyx` `read_mmio`/`write_mmio`, which run the APU up to the
current master clock and then read the port.

The port is a latch clocked by the SPC700, not by the console, so a console
read landing inside the SPC700's write window can see either byte. Modelling
it needs the item above (bus-access timing) to say where that window is.

### 5. Half-height objects (`$2133` bit 1) — done, and the answer was both

*Where*: `snes/ppu.pyx`, `_render_objects`.

This was left undone deliberately, with a note saying there were two readings
of the bit — that sprites halve in height on screen, or that they take
alternate source lines per field — and no way to choose between them, since
nothing in the library turned it on. The note ended "wait for a reference."

The reference turned up in krom's `InterlaceRPG`, which sets the bit. Both
readings are right and they are the same reading: an object covers half as
many scanlines *and* takes every other row of its own tiles, with the field
choosing which row, so the two fields together draw all of it at its proper
shape. The flip is applied first, on the full height, and the field moves the
other way once it has.

The demo goes from 34.65% to **100.00%** exact, which is as good as this kind
of evidence gets: 229,376 pixels, no tolerance.

### 6. S-DD1 — done

*Where*: `snes/sdd1.pyx`, registered in `snes/board.pyx`.

The chip is two things sharing eight registers, and they came apart cleanly.

**The mapper is written.** A 32 Mbit S-DD1 cartridge fits no standard map:
banks $C0-$FF are a 4 MB window of four 1 MB slots, and `$4804-$4807` say
which megabyte each slot shows. Below $C0 it is an ordinary LoROM. Street
Fighter Zero 2 does `JML $C00000` three instructions after reset, so with no
mapper it lands on the ROM's first bytes read through the wrong window,
executes them, and traps. With the mapper it boots, runs, and draws — packed
graphics as vertical stripes, because the second half is missing.
`tests/test_sdd1.py` drives all of this from a 65816 program on a cartridge
whose header says S-DD1, so the board is chosen the way a real one is.

**Which transfers the chip takes over is settled, and by measurement.** The
answer is not in the arming registers alone. Street Fighter Zero 2 sets
`$4800` and `$4801` to 1 at frame 10 and then leaves them there for the rest
of the run, while doing its sprite DMA out of WRAM on that same channel 0 —
so "the channel is armed" would decompress the sprite table. What settles it
is where the chip is: it sits on the cartridge and can only answer for
addresses it decodes. Arming *and* a source in the cartridge's own banks
picks out **2 transfers out of 496** across 600 frames, both in bank $D3,
both the shape of a graphics load:

| frame | source | bytes |
|---|---|---|
| 10 | `$D3:FB7D` | 2048 |
| 352 | `$D3:0000` | 1152 |

Both blocks begin `B0 00`, which is the documented two-byte header.

The bus tells the board when a channel starts and finishes a transfer
(`Board.dma_begin` / `dma_end`), because a chip on the cartridge cannot see
`$420B` but does see the reads that follow it.

**The decompressor is written too**, and Street Fighter Zero 2 draws its
Capcom logo and its title screen.

It is worth recording how, because the shape of it is the lesson. The
algorithm is Ricoh's ABS: a bit reader, eight Golomb decoders, a 33-state
probability ladder per context, and a context model that predicts a pixel
from the bits already decoded above and to the left of it in the same
bitplane. All of that is describable. What is not derivable is two tables of
constants — the probability ladder and a 128-entry run-length table — which
are hardware design data.

Those were fetched rather than reasoned out, and that was the right call:
the version written from memory first had at least four states wrong,
including one in the middle of the ladder that would have quietly corrupted
about a quarter of all runs. The tables are transcribed from the public
description of the algorithm reverse-engineered by Andreas Naive, with The
Dumper's hardware data behind it; the code around them is written here.

The remaining risk with transcribed constants is a typo, not a
misunderstanding, so that is what the test checks: the run table has to be a
permutation of 1 to 128, and the probability ladder has to be a ladder —
right takes you one rung up, wrong one down, the ends stay put. A
transposition cannot survive either check.

*What is still approximate*: the chip streams a byte at a time as the DMA
asks for them; here the block is unpacked up front into a buffer. The bytes
and their order are the same, and the console is halted throughout, so
nothing can observe the difference — but a game that armed a channel and then
did something other than a straight DMA would not be modelled.

### 7. SPC7110 — done, and the cartridge tested it for us

*Where*: `snes/spc7110.pyx`, `tests/test_spc7110.py`, `tools/spc7110check.py`.

Four devices in one package: the decompression unit, a data port that walks
the data ROM, a multiplier and divider, and the memory controller. The
decompressor is the only hard part — a binary arithmetic coder over a context
model of the pixels already decoded, with a move-to-front colour list — and
its 53-state probability ladder is transcribed rather than derived, for the
same reason the S-DD1's tables are.

Then the verification turned out to be sitting inside the cartridge.
Momotarou Dentetsu Happy's boot code reads sixteen bytes of save RAM, and if
they are not `SPC7110 CHECK OK` it jumps into an **SPC7110 CHECK PROGRAM
V3.0** held in its own ROM: nine tests of the chip in mode 1, a battery-backup
test in mode 2. That is rung one of the evidence ladder — a test written by
the people who made the hardware, against the hardware — and it arrived
without being asked for. All of it passes.

It also found a bug that had nothing to do with the SPC7110. The backup test
reads the whole save RAM and expects `$ff`, because a RAM cell that has never
been written is undriven and reads as ones. This emulator filled save RAM with
zeroes. Every other cartridge in the library either writes before it reads or
keeps a checksum, so nothing had ever noticed; this one reports NG, declines
to write the signature, and the game never starts. One line in `cart.pyx`.

*What is missing*: the RTC at $4840-$4842. Only Far East of Eden Zero has one,
it is not here, and a clock written blind is a clock that cannot be checked.

*What is approximate*: the chip's work takes no time. A real transfer sets
$480c bit 7 when it is ready and the ALU sets $482f bit 7 while it is busy;
here both are true the instant the register is written. A game that used the
delay to do something else would not be modelled — the same approximation the
S-DD1 makes, for the same reason.

### 7a. OBC1

Documented behaviour, nothing hidden inside, and nothing in the local library
needs it — so it would be written blind.

### 8. SuperFX — running, on one game and five tests

*Where*: `snes/superfx.pyx`, `tests/test_superfx.py`.

The instruction set is the bulk of it — the opcode range across the ALT1,
ALT2 and ALT3 prefixes, with FROM/TO/WITH deciding which register each one
reads and writes — plus the 512-byte instruction cache, the buffered ROM and
RAM readers, and the plot unit with its pixel cache.

The bug that cost the most time was not in any of that. `$98`-`$9d` are
`jmp r8` through `jmp r13`: the register is the opcode's low nibble, the same
as everywhere else. Written as `op - 0x98` it names r0 through r5 instead,
and Star Fox's GSU loops for ever at `$01:8199` on `jmp r11` — a hang with no
diagnostic, on the first frame that would have drawn a polygon.

The second thing worth writing down is a property of the *cartridge*, not the
chip. While the GSU is running with `SCMR`'s RON bit set it has the ROM, and
a console read of ROM returns a sixteen-byte vector table instead. That
includes the console's instruction fetches, so the routine that starts the
chip and waits for it cannot be in ROM; Star Fox's runs from work RAM, and so
does the one in `tests/test_superfx.py`. Getting this wrong looks like a
correct emulator running a program that mysteriously loses its own stores —
which is precisely how it presented while writing the tests.

*What is verified*: the instruction set, by something written outside this
project. krom's GSU tests — 31 ROMs, one per instruction, each walking the
register operands and checking the result and all four flags — all pass.
That paragraph replaces one written the day before, which said there was no
hardware test ROM for the GSU on this machine and that the whole chip rested
on one game and five unit tests. The tests existed; nobody had gone looking.
The lesson is not about the SuperFX.

*What is approximate*: the chip catches up to the console at each access and
at the end of every scanline rather than the two sharing a scheduler, so
cycles are counted but contention is not. Star Fox's intro leaves stray black
rectangles, and the catch-up model is the first place to look. `CLSR`'s
21 MHz mode changes the cycle counts but nothing here runs faster for it.

### 9. DSP-1/2/3/4, CX4, ST010/011

**Impossible as emulation, today.** Each is a microcontroller executing a
program mask-ROMed into the package, and that dump is not on this machine.
Without it the only route is reimplementing what the program does from its
documented effects — which is a different and much weaker thing, and is how
older emulators got Super Mario Kart subtly wrong for years.

Super Mario Kart is in the library and needs DSP-1. It currently renders a
flat screen. Leave it that way rather than guess.

### 10. SPC700 and DSP test ROMs — fetched, and all four fail

blargg's SPC tests are now on this machine, outside the repository, where
`tools/testroms.py` will boot them and capture what each says. They are the
first thing in this project that can say the emulator is *wrong* rather than
merely *unchanged*: they were not written from the same reading of the
documentation the emulator was.

The verdict, as of now:

| ROM | what it exercises | result |
|---|---|---|
| `spc_smp.sfc` | instructions, instruction timing, register behaviour, timers — sixteen sections | **PASSED** |
| `spc_mem_access_times.sfc` | when within an opcode each access happens | **PASSED** |
| `spc_timer.sfc` | timer read against write | **PASSED** |
| `spc_dsp6.sfc` | the echo unit, the envelope, key-on ordering, and the per-step timing of every voice register | **PASSED** |

Four failures, but not four problems: three of them were the same problem,
and one of those three is now fixed. `spc_timer` passes.

`spc_smp` is the useful one to read closely, because it is the only test here
that separates behaviour from timing, and it says the behaviour is right: the
instruction sections all pass, including the two — decimal adjust and the
full CMP matrix — most likely to hide an arithmetic mistake. It turns red
only when it reaches its timing section. `spc_mem_access_times` tests that
section alone and fails. And `spc_timer` fails on "timer read vs write",
which is the same question wearing different clothes: what a read sees
depends on which cycle of the instruction it happens on, and here the whole
instruction's cycles are charged in one lump when it finishes.

So item 1 — SPC700 bus-access timing — was not one of three open APU items.
It was the one that three of the four tests were waiting on, which made it a
much better-defined piece of work than it looked when it was written down
from the documentation alone. It is now largely done and `spc_timer` passes.
`spc_dsp6` is the one genuinely separate failure, and it belongs to item 2.

One thing was fixed on the way, and it is worth noting that it did *not* fix
the test. The timers' first stage is a scaler off the SPC700's clock, and it
free-runs whether or not the timer is enabled: an enable resets the divisor
and the output counter but not the scaler, so the first tick after an enable
lands wherever the scaler happened to be. This emulator reset all three,
which put every timer in phase with whenever it was switched on. That is
wrong on the documentation's own terms and is now right, and `spc_timer`
still fails, because what it is measuring is finer than that.

Note also what getting them to run turned up. All four have a blank internal
header — no title, no checksum — and the header detector counted those zeros
against a candidate, so it rejected the images outright. A zero in the title
field is not evidence of anything; it means nobody filled it in. Other
control bytes still count against, which is what the check was for. All 66
cartridges in the local library detect exactly the same header at the same
offset with the same map mode after the change.

---

## The six partial items

### `$4200`/`$4210` single-cycle read race

*Where*: `snes/bus.pyx`, `read_mmio` at `$4210`.

Enabling NMI while the flag is set fires at once, and the flag clears both on
read and at the top of the frame — all covered by
`test_timing.py::test_rdnmi_clears_on_read_and_at_the_top_of_the_frame`. What
is open is the one cycle where a read of `$4210` coincides with the flag
being set, where hardware can return either value and lose the interrupt.
Needs the CPU to charge the read at sub-instruction granularity to even
express.

### Interrupt sequence, cycle by cycle

*Where*: `snes/cpu.pyx`, `interrupt()`.

The effect is right — the correct bytes are pushed, the B flag is computed
without clobbering the X width bit, the vector is right. What is not modelled
is which of the seven cycles does which push. Only observable through a bus
trace against a reference.

### OAM priority rotation

*Where*: `snes/ppu.pyx`, `_render_objects`, `first = ...`.

Rotation moves the first sprite of the scan, which is modelled. The reload
of `$2102` has its own timing during rendering that is not.

### H/V counter latch race

*Where*: `snes/ppu.pyx` `latch_counters`, `snes/bus.pyx` `$4201`.

Both trigger paths work and `$213F` reports and clears the flag — six tests.
The open part is a latch landing on the same cycle as a read.

### SA-1 bus arbitration

*Where*: `snes/sa1.pyx`, `SA1Space.speed`, which returns a flat 2.

The SA-1 catches up to the console rather than the two sharing a scheduler.
Where they want the same ROM or BW-RAM in the same cycle, hardware makes one
wait; here neither does. A game whose timing depends on losing that race
would not see it. Fixing this properly means putting both processors on the
event scheduler in `snes/bus.pyx` rather than running one to catch up.

Note this is the *only* SA-1 gap left: the timers and both kinds of character
conversion are now implemented (though unexercised, per the table above).

### A save state now carries the cartridge — and how the omission happened

*Where*: `tools/gen_state.py`, `snes/system.pyx`, and an `extra_state` on two
boards.

Every board's state used to be left out of a save state: the SA-1's second
processor and its I-RAM, the S-DD1's slot registers, the SuperFX's registers
and pixel cache, the SPC7110's windows and decompressor. A state loaded
cleanly and the game misbehaved afterwards, and rewind — built on the same
serialiser — was wrong in every game with a chip on the cartridge.

`tests/test_state.py` catches it the moment it is pointed at one of those
games, which is how this was confirmed before it was fixed: Star Fox's replay
diverged at the third checkpoint. It now passes for all four families —
Star Fox (SuperFX), Super Mario RPG (SA-1), Street Fighter Zero 2 (S-DD1) and
Momotarou Dentetsu Happy (SPC7110).

Three things were needed beyond the mechanical part:

*The state says which board it was saved with*, so one cartridge's chip state
cannot be loaded into another's. The version went to 3; older states are
refused rather than half-loaded.

*Two boards keep something the generator cannot emit.* Generated blobs are
fixed-size `memcpy`s, and the SuperFX's work RAM is sized by the cartridge,
while the SA-1 has a whole second CPU hanging off it. Both have a small
hand-written `extra_state`/`load_extra` pair, and nothing else does.

*The generator now checks itself.* This is the part worth keeping. A
hand-written serialiser drifts from the class it serialises; a generated one
drifts more quietly, because a field added to a `.pxd` and not to the spec is
simply absent from every state and nothing complains. That is exactly how the
boards went missing. `check_complete()` now parses each `.pxd` and fails the
generator unless every declared field is either serialised or named in
`EXCLUDED` with a reason. It found one on its first run: the bus's `timer_irq`
— whether the H/V timer is asserting an interrupt — had never been saved, in
code nobody suspected.

### Differential trace against a reference

Covered at the top. The tooling is done; the reference is not available.

---

## The titles that do not render, and one that only looked like it

| title | status | what is known |
|---|---|---|
| Super Mario Kart | flat | DSP-1, needs firmware not present. Expected. |
| Momotarou Dentetsu Happy | flat | **Correct.** A blank cartridge boots its own check program; see item 7. |
| `Mix.smc` | black | **The image is broken, not the emulator.** See below. |
| `SMWREX.smc` | black | **The image is broken, not the emulator.** See below. |
| Rudra no Hihou (J), and its translations | ok | **Not a defect.** Its opening finishes at frame 7200; the tool gave it 900. |

Both of the two black ones are Super Mario World hacks that destroy something
the base game still needs, and both are proved so by running unmodified
`Super Mario World (E)` down the same path and watching it work.

### Rudra no Hihou — not a defect, and the write-up that said it was

This section previously described Rudra no Hihou as the last game-level bug in
the library, with a diagnosis: the main thread deadlocked waiting on a job
queue nobody filled. Every observation in it was accurate and the conclusion
was wrong. The game renders its opening perfectly — the four character
portraits and the tower — at **frame 7200**, and `batchtest` was giving it 900.

What the wait loop at `$C0:04A8` actually is: the engine's idle state. Its work
is posted from the NMI and the main thread spins between jobs, so catching it
there proves nothing. `$00:063B` reading zero proves nothing either — it is
zero whenever the queue happens to be empty. Two hours went into the APU
handshake, which was working the whole time, echoing every byte of a
forty-frame sound upload.

The lesson is worth more than the bug would have been:

*A verdict from a tool with a fixed window is a statement about the window.*
`batchtest` runs 900 frames and reports the best one, which is right for
catching fades and wrong for a game whose opening takes fifteen seconds. It
now keeps running when a title has drawn nothing — `PATIENCE` times the
normal window — and marks what it had to wait for as "slow to start". Rudra
needed 1200 frames to show something and 7200 to finish.

*Ask "is it stuck, or is it slow" before asking why it is stuck.* One command
answers it. The whole investigation below the first hour was spent on the
second question without having answered the first.

What the investigation did leave behind is worth keeping: `tools/spcdisasm.py`
exists now, so the APU can be read as well as heard, and it was needed for
exactly the reason this project keeps rediscovering — the emulator could run
that code but nothing could show it.

**The library now has no unexplained failure.** Every title either renders, is
a proven-broken image, needs firmware that is not here, or is doing what the
hardware would do.

## The first timing defect found, and fixed, by a hardware oracle

Every instruction test in this project settles *what* an instruction computes.
Sour's `dma_irq_test` settles *when* something happens: it arms an H/V IRQ,
starts a DMA, and counts how many instructions finish before the interrupt is
taken. Its README carries the numbers a real console gives.

We matched **none** of the fourteen. Every one was short: hardware ran one or
two more instructions than we did.

The mechanism, from bsnes's own comment on the matter, is a two-stage
pipeline. The 65816 decides whether to take an interrupt *a cycle before the
instruction ends*, and acts on that decision at the boundary. Three
consequences, all of which the test measures separately:

- **CLI lets an interrupt in one instruction late.** The decision for the
  boundary after CLI was made while I was still set.
- **SEI shuts one out one instruction late**, for the same reason — and the
  flag is tested again when the interrupt is actually taken, which is what
  stops SEI's own decision from letting one through.
- **A DMA hides the lines** for the cycle it ends in and the two after it, so
  an interrupt that became pending during the transfer waits for the
  instruction after next. A two-cycle instruction and a three-cycle one give
  different answers, which is exactly what the expected table shows.

That last number — how many cycles the DMA hides the lines for — is the one
thing here that was fitted rather than derived: 2 gives 6 of 14, 3 gives 13,
4 gives 7. Fitting one parameter to fourteen documented values is calibration
against an oracle, not guesswork, and it is written down here as the one
number in this file that came from the data rather than from a document.

The golden interrupt trace changed, and was re-recorded deliberately after
reading the diff: it had encoded the old behaviour, taking the IRQ
immediately after CLI. `test_cpu.py` now pins the delay directly.

## VRAM address remapping, checked without a reference

$2115's low bits remap the VRAM address so a game can write tile data in
whatever order suits it. Nothing in the library exercises it and no reference
picture covers it, so it had never been checked.

undisbeliever's ROMs check it in a way that needs neither: they come in pairs
where one writes the data plainly and the other writes it in a different order
with remapping on, and both must produce **the same picture**. That is a
property of the hardware, not of anyone's description of it — if remapping
were ignored the second would scramble, and if it were applied when it should
not be the first would.

Eleven ROMs across 1, 2, 4 and 8 bpp, word and split modes: every group agrees
on one picture, and the pictures are not blank. `tools/vmaintest.py` keeps it
that way.

## Sprites that name the tiles they came from

neser's OBJ ROMs are drawn with undisbeliever's `hex8` glyphs, where every
8x8 tile in VRAM is a picture of its own number. That turns a capture back
into data: match each 8x8 block of the screen against the tile bitmaps
sitting in VRAM and the picture says which tiles were fetched. A block is
matched against the tile as stored and against its three mirrors, because a
flipped sprite draws flipped glyphs — and which mirror matched is itself
worth reporting.

The answer that gives is one a person can argue with. "The V-flipped sprite
fetched 30/31 above 20/21" is a claim about the hardware, published in
neser's README and agreed by ares, higan, Snes9x and the SNESdev wiki (with
Mesen2 dissenting at F0/F1 above E0/E1). "The screen hashes to a1b2c3" is a
claim about nothing.

It found a real defect. V-flip on the undocumented rectangular sizes does
not mirror against the whole height: a 16x32 flips as two stacked 16x16
squares, each turning over in place. We mirrored against the full height,
so a flipped 16x32 read 10/11 above 00/01 instead of 30/31 above 20/21.

`tools/objglyphs.py` now reads all eight OBSEL size selects off the screen —
their tile rectangles and that nothing is drawn past the bottom or right
edge — against the size table quoted from the SNESdev wiki's PPU registers
page, plus the three y-wrap placements. Nineteen checks, all passing. It
was made to fail on purpose first: widening size select 7's large sprite to
32x64 in the renderer produced `and it drew past the bottom edge: 40 41 42
43`, which is what a check has to be able to say before its silence means
anything.

## Speed, measured for the first time

An emulator that is accurate and cannot run at sixty frames a second is not
finished, and this had never been measured. It is now, and the first
measurement was wrong in an instructive way: 46.8 fps, taken while a
test-ROM suite was running in another window. On a quiet machine the same
build did 88 fps. *Never benchmark against a busy machine* -- and the same
discipline that applies to a frame budget applies to a stopwatch.

The real numbers, Super Mario World, on this machine:

| | before | after |
|---|---|---|
| emulator core | 11.4 ms/frame (88 fps) | **4.6 ms/frame (210 fps)** |
| play loop total | 21.9 ms | 14.8 ms |
| frames over the 16.67 ms budget | 94.6% | **15.4%** |

Where the time went was measured rather than guessed, by removing one stage
at a time and timing what was left:

| stage removed | cost |
|---|---|
| composition | **63%** |
| backgrounds | 24% |
| sprite painting | 15% |
| sprite evaluation | 1.5% |

So composition was two thirds of everything, and the fix is the one bsnes
uses: a table from brightness and fifteen-bit colour straight to the pixel
that leaves the PPU. Two megabytes, built once, and it replaces three scaling
lookups and three channel expansions per dot with one read. 88 fps to 210.

Two things are worth taking from this beyond the number. The first is that
*the optimisation was safe because the oracle existed*: krom's reference
pictures still match on 34 of 35 demos, pixel for pixel, and the PPU suite's
scene hash is unchanged. Without that, a 2.5x rewrite of the hot path would
have been a leap of faith. The second is that a per-pixel tile cache -- the
obvious optimisation, fetching the tilemap entry once per eight pixels
instead of once per pixel -- measured *the same* and was reverted. VRAM is
64 KB and never leaves cache; the branch cost as much as the reads saved.

**The display path, next.** Blitting and flipping cost 7.0 ms of the 14.8 —
more than the emulator did. It was `pygame.transform.scale` working through
2.2 million pixels on the CPU. Handing SDL a texture at the size the PPU drew
it and letting the GPU stretch it to the window costs nothing here at all:

| | software scale | SDL renderer |
|---|---|---|
| draw and present | 8.20 ms | **0.66 ms** |
| play loop total | 19.59 ms | **12.60 ms** |
| frames over budget | 77.0% | **12.0%** |

The machine this was written on has no display, which is exactly why the
fallback matters: `play.py` tries the SDL renderer, and what happens when it
is not there is what the emulator did before. `--software-scale` forces the
old path, which is how the table above was measured. What cannot be checked
here is whether a real GPU makes the presentation faster still — it can only
help, and the CPU side of the saving is measured, not assumed.

## The INIDISP glitch: measured, understood, and deliberately not modelled

undisbeliever's 29 INIDISP ROMs come with **photographs of a real Super
Famicom** running them, which makes them the closest thing here to hardware.
They probe one behaviour: a write to `$2100` can be latched with bit 7 taken
from the data bus rather than from the value written, so a write of `$0f`
briefly forces blank, or a write of `$8f` briefly *un*-blanks — for about one
dot.

Our rendering of these ROMs matches the photographs in everything except the
glitch. `inidisp_hammer_0f00` draws the same brick wall, the same "4 bpp"
labels and the same OBJ sprite in the same places. What is missing is the
one-dot artefact itself.

It stays missing, on purpose:

- It is **not deterministic**. The author's own note says the HDMA cases
  "appear ~40% of the time on my console" and need a few resets.
- It is **console-dependent**: his 3-chip machine glitches where a 1-chip one
  does not, and vice versa for the inverse case.
- It is an **analogue latching artefact** described in a forum post, not a
  documented register behaviour, and no reference emulator models it.

Modelling it would mean inventing a rule for something the hardware itself
does inconsistently, and then having no way to tell whether the invention was
right. Three of the ROMs are marked "(does not glitch)" and we agree with all
three, because we never glitch — which is a defensible model of a 40%
phenomenon, and an honest one as long as it is written down.

## The day the library was read

Twelve defects were found and fixed in one day, and not one of them was
found by fetching something new.  Every one came from something already
on this machine that had been saying the same thing for months.

  * A 65C816 test ROM in the library prints "Running tests... Failed" and
    a number.  It said 27.  It had been recorded as "flat" by the batch
    runner -- which is what white text on black looks like when you count
    colours -- and never read.  Five defects came out of it, four in
    emulation mode: the pointer wrap of (dp,X) with a non-zero DL, the
    straight-through pointer fetches of [dp] and PEI, the B flag COP
    pushes, and the family of stack instructions the 65816 added, which
    work on all sixteen bits of S while they run.  It now prints Success,
    all 1610 tests.
  * The same author's SPC700 ROM sat beside it, equally unread, failing
    on a divide by zero.  DIV was special-casing a zero divisor; the
    hardware has no such case.  1319 tests, all passing now.
  * Tengai Makyou Zero carries a self-test written by whoever built the
    cartridge, reachable past the corrupt-save prompt the library run had
    been recording as "flat".  It printed `RTC TIME  NG`.  Reading the
    exchange it performs said why: it writes 23:59:59 on 31 December '99
    with weekday 6 and wants the roll across midnight, month, year and
    century back with the weekday carried by one.  Three separate
    mistakes, each of a different kind.  It prints `ALL OK` now.
  * Jonas Quinn's mul_behavior said the multiplier was not a multiplier:
    it is a shift-and-add over eight steps, a write during a run clears
    what has accumulated, and the second operand ends up in the division
    registers.  His notes beside the ROM contain the algorithm.
  * A proof about colour maths, measured on a console with a copier, sat
    beside its own answer and two captures.  We are on the right side of
    it; nobody had checked.
  * absindx's SA-1 register dump showed $230E answering an invented
    revision number where a cartridge reads open bus.

What the day cost, in the end, was not documentation and not technique.
It was the habit of reading what is already answering.  Three tools came
out of that: `verdicts.py`, which boots every test ROM, presses a button
in case it is waiting for one, and reads its screen back as text --
reporting "nothing readable" rather than "fine" for a screen it cannot
turn into words; `cputest.py`, which keeps the two instruction-set ROMs
read; and `checkall.py`, which runs every oracle here in one command and
keeps three outcomes apart rather than two: passed, failed, and could not
run.  The third is not a pass.

One thing was also *not* done, twice, and that matters as much.  The
mode 7 commands of the DSP-1 are answered by geometry worked out here
because their scaling is not published, and three attempts produced three
different wrong pictures; iterating until one looked like a road would
have been fitting a guess to a screenshot.  And an unattributed note
disagrees with the SNESdev wiki about what the object interlace bit does
to sprite sizes, in cases no reference picture covers; the behaviour that
matches a reference stayed, and the disagreement was written down instead
of decided.

## How to verify anything here

```
python build.py                       # the cores are Cython; rebuild after edits
python tools/runtests.py              # ten modules; ROM-dependent ones skip
python tools/batchtest.py <rom-dir>   # boots a library, best frame per title
python tools/playtest.py <rom>        # scripted buttons, screenshot per step
python tools/testroms.py <dir>        # hardware test ROMs, verdict per ROM
python tools/featureprobe.py <dir>    # which features anything actually uses
python tools/difftrace.py check       # committed traces, cycle for cycle
python tools/dspdiff.py <probe>       # this DSP against blargg's, sample by sample
python tools/spc7110check.py <rom>    # the check program inside Momotarou Dentetsu Happy
python tools/kromtests.py <dir>       # 66 instruction tests, verdict read from VRAM
python tools/ppucompare.py <dir>      # PPU demos against their own screenshots
```

Two habits worth keeping. `batchtest` judges on the best frame of a run, not
the last — it used to judge on the last, and reported working games as black
because it caught them mid-fade. And when a golden trace changes, re-record
it deliberately (`difftrace record`) after looking at the diff, never
reflexively; the whole point is that a moved cycle has to be noticed.

---

## The day the instruments were read

A later session, and the shape of it was different from the ones above: most
of what it found came from fixing the things that do the looking, not the
thing being looked at.

**What is verified now, by something outside this repository:**

| what | by what |
| --- | --- |
| every 65816, SPC700 and GSU instruction | krom's 66 cartridges, all passing |
| the sound chip, in depth | blargg's eight, including spc_dsp6's sixty checks |
| the SPC7110, including its clock | the manufacturer's own check program in two games, ALL OK |
| the SA-1's memory protection | absindx's 222 tests, matching a photograph of real hardware |
| VRAM address remapping at every depth | undisbeliever's cartridges, judged against each other |
| the multiply and divide unit | Jonas Quinn's four, two of them checksums over whole tables |
| save states and rewind | the suite's own, which had never run before today |

**The instruments that were lying, and what each cost:**

* `Bus.read()` resolves by page kind, and the register file is not a page --
  so reading a DMA channel returned whatever the bus last carried.  All eight
  channels agreed, uniformly and fictitiously, and an investigation into
  Mario Kart was built on it before the reading was checked against the path
  it had actually taken.  `Bus.dma_channel()` exists because of that.
* `tools/verdicts.py` decoded VRAM from word zero as though the tilemap were
  always there.  On most cartridges word zero is the font, so it returned the
  same bytes for every ROM sharing one and the same bytes at every frame while
  the screen changed.  It called blargg's spc_dsp6 hung twice.  Reading four
  hundred and twenty-six screens "unreadable" was mostly this; fixing it left
  three hundred and sixty-six and turned up six failures nobody had seen.
* `tools/runtests.py` printed SKIP for save states and rewind all session,
  and the reason was a line of setup, not a missing cartridge.  There are five
  hundred on this machine.

**What was decided against, with reasons, rather than left vague:**

* `$230E`, the SA-1 version register: the cartridge that looks like its
  oracle branches unconditionally to its own failure path.  It cannot pass.
  Two sessions have now read that FAILED as a verdict; the second one is
  written down so a third does not.
* `$F0` bits 4-7, the SPC700's clock and timer speed: blargg's own notes give
  the formula and twelve measurements confirm it.  Not implemented, because
  those bits stretch the sound chip's clock -- the one piece of timing that
  currently satisfies eight audio cartridges and a real game's music -- and
  no commercial game writes them.
* An interrupt-line offset of +24 master cycles, which fixes exactly one gate
  of one cartridge and is contradicted by five others.

**Still open, with the next step named:**

* Mario Kart's flat road.  Seven candidates eliminated by measurement,
  including the DSP-1.  The game never fills its per-line matrix buffers and
  nothing observable writes them.
* Four interrupt cartridges, now readable rather than red: they keep the byte
  the failing gate saw at $70:0001 and a running count beside it, so the
  question is a byte and a gate number rather than a colour.  The processor
  looks for an interrupt before its instruction's last cycle now, which is
  what gate 1 wanted; gate 2 wants the same landing one instruction earlier
  and gets the same one as gate 1.  Between those two gates the program
  changes only how long it waits, so what is left is the length of that wait
  -- the delay at $02:807D with a different argument, or the V-timer being
  re-armed by the $4200 write between them.  Neither is measured yet.
* Four homebrew cartridges that draw nothing.  `tools/whystuck.py` gives each
  a different answer in seconds.
* The DSP-1's Mode 7 commands are still worked out from geometry.  Firmware
  would remove the guessing and unlock six chips at once.

## Holding the last tile fetch

Sampled with py-spy over Super Mario World, native stacks, 15,000 samples:

    30.5%  _render_bg          12.0%  _paint           7.6%  Bus.read8
     7.4%  _compose             3.9%  _compute_windows 3.7%  DSP.tick

`_render_bg` walked the tilemap and the character data once per *dot*.  A
tile is eight dots wide, so seven fetches in eight asked VRAM for what the
dot before had already read, and then decoded the same map entry again.
Holding the last map address and the last character address and comparing
turns those into a compare.  The addresses are the whole key: everything
that could change the answer -- the scroll, the mosaic, per-tile offsets in
modes 2, 4 and 6, either flip -- moves one of them first.

    215.3 -> 236.1 fps on Super Mario World, best of eight runs

Best of eight because single runs on this machine vary by up to 70% -- there
was a second emulator on the other core for part of this, and the first
comparison came out backwards because of it.  Two runs said the change made
things twice as slow; eight said it made them a tenth faster.

Guards: all twenty test modules, krom's 66 reference pages, ppucompare's 35
demos exact to the pixel, and the VMAIN pairs.  A renderer change that
alters no pixel anywhere is the only kind worth having.

## Not drawing layers that are on neither screen

`_render_bg` ran for every background the mode has, whether or not $212C or
$212D had it on.  Nothing reads the result of that: `_paint` returns at once
for a layer on neither screen and it is the only thing that looks at
`bg_idx`.  The sprites are deliberately left alone -- their evaluation sets
the range and time overflow flags that $213E reports whatever the screen
registers say, so skipping them would be observable.

How often it matters, sampled over ten seconds of ten library titles:

    Dragon Quest III   100%    Dragon Quest VI    100%    Battle Dodgeball II  75%
    Bahamut Lagoon      50%    Donkey Kong Country 50%    Final Fantasy IV     50%
    Dokapon 3-2-1       25%    Dragon Quest V      25%

-- the share of background layers on neither screen.  Super Mario World is
not in that list because it keeps all of its on, which is why the benchmark
this work started from showed nothing at all.

    Bahamut Lagoon   3.768 -> 3.588 s of processor time, best of five

That measurement took three tries to get honest.  Wall clock said the change
made things slower; so did processor time, once, by forty percent.  Both
were another emulator on the next core.  The reading that stands is the one
that reproduced, and it agrees in direction with the mechanism -- which is
the only reason to believe a five percent number on this machine at all.

## Not filling a window mask nobody is looking through

`_compute_windows` wrote a zero per dot per layer for every layer with no
window switched on -- six passes over the line, per segment, for a value its
readers could have worked out.  A game that writes a register mid-line gets
several segments, so it paid for it several times a line.

Sampled over ten seconds of eight library titles, the share of the six
window users with neither window enabled:

    Bahamut Lagoon, Battle Dodgeball II, Dokapon 3-2-1, Donkey Kong
    Country, dq12j, Dragon Ball Z Super Butouden 3        all 100%
    Dragon Quest III, Dragon Quest VI                     0%

So for six of those eight the fill was entirely waste, every segment of
every line, and for the other two none of it was.  The readers ask the
question themselves now: `_paint` treats a layer with no window as
unwindowed whatever $212E says, and `_compose` hoists the same question for
the colour window out of its loop.

    Bahamut Lagoon   2.081 -> 2.033 s of processor time, minimum of twelve

That is 2.3%, against a spread of 0.8% between runs of the same build, so
the timing on its own would not carry it.  What carries it is that the work
removed is exact and the profile said `_compute_windows` was 4.3%; two
percent measured against four percent available is the right order.  Every
pixel-exact reference still matches.

## Two things that did not work, and how to measure on this machine

`_paint` reads five things per dot that cannot change during the call --
which buffer the layer comes from, whether the screen is hires, whether
direct colour applies, whether the layer is windowed, which screen is being
written.  Hoisting them into locals and selecting the target buffers as
pointers made it **2.3% slower**, twice, measured properly.  The compiler
was already hoisting what mattered, and turning two fixed arrays into
pointers costs more in aliasing than the branches saved.  Reverted.

Measuring anything here needed a method first.  Single runs vary by up to
70%; the minimum of eight helps but not enough, because the load drifts
between one build's batch and the next.  Three times in one session a
change measured as a large regression and then reproduced as an
improvement, or the reverse.

What works: build both versions, keep the two `.so` files, and alternate
them run by run, taking each one's minimum.

    cp with.so    snes/ppu.cpython-312-x86_64-linux-gnu.so   # then time it
    cp without.so snes/ppu.cpython-312-x86_64-linux-gnu.so   # then time it
    ... eight times, alternating

Interleaved that way both versions see the same load, and the answer held
across two runs of the experiment even though the absolute times nearly
doubled between them.  Rebuilding between measurements does not just cost a
minute; it puts each build in its own stretch of time, which is exactly the
thing that has to be controlled for.

## The library as a regression detector

`batchtest.py` already said, in a comment, that its worth is in comparing
one run to the next.  There was nothing to compare against: the only
fingerprint it computed used `hash()`, which CPython randomises per process,
so it could count how often a picture changed inside one run and could not
say whether today's picture was yesterday's.

It now takes a digest of the final frame that does not move between runs.
Recording and checking are two different words:

    python tools/batchtest.py <romdir> --write-baseline .library-baseline
    python tools/batchtest.py <romdir> --baseline       .library-baseline

The second reports what changed, what is new and what has gone, and exits
non-zero if anything did.  With no baseline there it stops and says so
rather than making one.  That distinction is not tidiness: with a single
flag that writes when the file is missing, the first run of an automated
check creates the thing it was meant to check against and reports success --
which is the exact failure this tool exists to catch, and is what an APK
build did three times over earlier the same day.

`tools/checkall.py --slow` runs the comparison last, so everything else has
reported by the time it finishes.

Three things had to be fixed before the first baseline was worth anything,
and each was invisible until the file existed:

* **It was keyed by file name.**  Two names appear twice in this library, in
  different folders, so their answers overwrote each other and every run
  would have reported a change decided by which was read last.  Keyed by
  path from the ROM directory now.
* **A subset counted as a disappearance.**  With `--filter` or `--start` the
  rest were not attempted, and calling that "gone" made every subset check
  fail.  Only a whole run can say something has gone.
* **The runs were not reproducible.**  Two byte-identical copies of one
  cartridge gave two different final frames, which looked like the emulator
  had stopped being deterministic.  It had not: one of them had a `.srm`
  beside it and the other did not, so one booted into a saved game.  A run
  meant to be compared has to depend on the cartridge and nothing else, so
  `System(..., use_saves=False)` exists and batchtest uses it.

That last one turned up something else on the way.  Battery saves are keyed
by the ROM's *base name* in `pysnes/saves/`, so two different games with the
same file name share a save slot.  Nothing in this library is hurt by it --
the two duplicate pairs are byte-identical files -- but it is a real hole
and it is written down here rather than fixed blind.

The baseline is not in the repository and `.gitignore` keeps it out.  It is
a list of one machine's game library, and a collection that exists here does
not belong in a tree anyone else will clone -- the same reason the ROM path
lives in `.romsdir`.

Two things it refuses.  A baseline taken over a different number of frames
is an error rather than a comparison, because the frame count decides the
picture.  And `--play` cannot be compared at all: pressing buttons makes a
run depend on when the presses land, which is exactly the thing a regression
detector must not have.

Why this and why now: a whole day of changes to HDMA channel gating, to when
the processor looks for an interrupt, and to two renderer paths went in
against a library check that was read by eye, twice, twenty-five minutes at
a time -- and one of those readings was wrong because a flag was left off.

## The two audio checks were not running at all

`checkall.py` says of itself that something not run is not something that
passed, and then reported both DSP comparisons as "skipped" or "could not
run" for as long as nobody exported a variable.  The probe had never been
built on this machine.  So the strongest audio evidence this project has --
blargg's own implementation, the same author as the test ROMs -- was inert,
and the routine looked green.

Built now, from the library the source files already told us to clone:

    g++ -O2 -o dspprobe dspprobe.cpp SPC_DSP.cpp
    g++ -O2 -I. -o play_spc demo/play_spc.c demo/demo_util.c \
        demo/wave_writer.c snes_spc/*.cpp          # minus dspprobe.cpp

and both say the same thing:

    DSP alone, sample by sample     0 of 14 scripts differ
    a game's driver, both chips     correlation 0.9829, rms 476 against 471

The binaries live in `~/.local/share/pysnes/`, outside the repository --
they are somebody else's code built here.  Both tools look there when the
environment variable is unset, because a check that depends on remembering
to export something is a check that stops running and does not say so.

The second `*.cpp` glob has to exclude `dspprobe.cpp` or the link fails on
two `main`s, which is worth a line because the instructions in the source
files do not mention it.

## Two saves that were one

Battery saves were kept as `saves/<rom base name>.srm`.  Sorting a
collection into folders makes duplicate base names ordinary -- this library
has two pairs -- and two different games sharing one wrote over each other's
battery, with the second to be opened losing a save and nothing said.

The cartridge's own checksum is in the name now:

    saves/BahamutLagoon-B856.srm

Older saves are still picked up, in order: the name without a checksum,
which is what this wrote before, and then one sitting beside the ROM, which
belongs to whatever emulator put it there.  Either is read once and written
back under the new name.

## A timing assertion that measured the machine

`test_rewind` checks that recording costs a small fraction of a frame.  It
had already learned once not to assert on the absolute frame time, because
the same build measures 11 to 24 ms depending on what else is open, and to
assert on the *difference* instead.  The difference was still measured as
one batch of recorded frames followed by one batch of plain ones -- two
stretches of time as much as two workloads -- and it failed at 5.43 ms while
a library sweep ran beside it.

Interleaved in short rounds, both halves see the same load: 3.55, 3.89 and
3.80 ms over three runs with that sweep still going.  It is the same lesson
as the benchmark method above, and the test had to learn it twice.
