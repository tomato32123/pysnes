# What is left, and what it would take

`roadmap.md` is the checklist. This is the working brief behind it: for each
thing still open, what it actually is, where in the code it goes, how you
would know you got it right, and what — if anything — makes it impossible
today. Written so it can be picked up cold.

As of this writing: **42 done, 5 partial, 5 untouched** of 52 items. The
66-ROM local library boots 63 titles; the three that do not are listed at the
end. One wants a coprocessor whose firmware is not here, and two are
defective ROM images — proved defective, not assumed so. No title in the
library now fails for a reason inside this emulator.

The 63rd is Street Fighter Zero 2, which was a black screen until the S-DD1
was written and now draws its Capcom logo and its title screen.

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

### A save state does not carry the cartridge

*Where*: `tools/gen_state.py`, whose `SPECS` list names the CPU, the bus, the
PPU and the APU — and no board.

Every board's state is left out: the SA-1's second processor and its I-RAM,
the S-DD1's slot registers, the SuperFX's registers and pixel cache, the
SPC7110's window registers and decompressor. Saving and loading in Star Fox
restores the console around a GSU that is still wherever it had got to, which
was measured rather than assumed:

    saved  r15=fbe6 pbr=06
    loaded r15=b301 pbr=01

For the same reason rewind is wrong in any game with a chip on the cartridge —
it is built on the same serialiser. Nothing warns; the state loads cleanly and
the game misbehaves afterwards.

The fix is mechanical: add the boards to `SPECS` and regenerate. It needs one
decision first — a state has to record *which* board it was saved with, or a
state from one cartridge will load into another.

### Differential trace against a reference

Covered at the top. The tooling is done; the reference is not available.

---

## The three titles that do not render

| title | status | what is known |
|---|---|---|
| Super Mario Kart | flat | DSP-1, needs firmware not present. Expected. |
| `Mix.smc` | black | **The image is broken, not the emulator.** See below. |
| `SMWREX.smc` | black | **The image is broken, not the emulator.** See below. |

Both of the two that were "unexplained" are Super Mario World hacks that
destroy something the base game still needs, and both are proved so by
running unmodified `Super Mario World (E)` down the same path and watching it
work. Nothing in the library now renders nothing for a reason inside this
emulator.

Kunio-kun no Dodge Ball was on this list as "flat, unexplained". It is not:
it draws its title screen, takes START, and reaches the team menu. What was
being measured was a run judged before the game had drawn anything. It is the
second time a title has been libelled by the sampling and not by the
emulation — the first was what made `batchtest` judge on the best frame
rather than the last — so before chasing a title that renders nothing,
confirm it with input rather than with a fixed frame count:

```
python tools/playtest.py <rom>          # scripted buttons, screenshot per step
```

### `Mix.smc` — a defective ROM image

Worth writing down in full, because the shape of the argument is reusable.

The image is a Super Mario World hack, and the hack's IPS patch sits beside
it. `Mix.smc` is byte for byte `Super Mario World (E) (V1.1)` **with its
512-byte copier header** plus `Mix.ips`, so it is what the author shipped,
not a bad copy of it.

What the patch does, among 4869 other records, is overwrite `$00:B992-$B9AA`
with pointer-table data. In the base ROM those 15 bytes from `$00:B997` are
the routine that reads the next byte of a compressed stream and carries the
pointer over a bank boundary — and the decompressor at `$00:B8F1`, which the
patch leaves alone, still calls it. Boot therefore runs into a table:

```
$00:9399  JSR $A99A         ; still stock
$00:A9AD  JSL $00BA3C       ; still stock -- decompress GFX file $28
$00:BA5B  JSR $B8F1         ; still stock
$00:B8F6  JSR $B997         ; still stock -- and $B997 is now a pointer table
```

The tell is that unmodified `Super Mario World (E)` reaches `$00:B997`
by the same four calls at instruction 949,669 of its own boot, one frame
either side of where `Mix.smc` arrives. The path is the base game's, not
something the emulation invented, so there is no emulator behaviour that
could avoid it.

`MixA.smc` — the same author's next release, ver 1.52 — boots and plays.

### `SMWREX.smc` — the same verdict, by a different route

Also a faithful patch of `Super Mario World (E) (V1.1)`, headered, this time
expanded to 4 MB. The mapping is not the problem, despite the size: the hack
puts its own code in the gap before the internal header at `$00:FFAD` and
reaches it with a `JSL`, which only works if the banks land where it is
putting them.

It never leaves forced blank. The patched reset does `SEI / CLC / XCE / JML
$80859A` — and `$00:859A`, which the patch does not touch, is the middle of a
table of 24-bit pointers in the base game. The CPU chews through it as
instructions (harmlessly: `TSB` and `ORA` on ROM addresses) and falls into
real code at `$00:85D4`, which loads a pointer from `$00:84D0` and calls the
VRAM upload routine at `$00:871E`. That routine walks a list of DMA
descriptors, six bytes each, stopping at the first whose first byte has bit 7
set. The list lives at `$7F:837D`, in WRAM.

The measurement that settles it:

| | reaches `$85D4` | `$7F:837D` at that moment |
|---|---|---|
| `Super Mario World (E)` | instruction 1,160,333, frame 70 | `$FF` — an empty list, so the routine returns at once |
| `SMWREX.smc` | **instruction 24**, frame 0 | `$55` — untouched power-on fill |

The hack's reset lands past the million-odd instructions of initialisation
that put the `$FF` there, so the list never ends and the routine marches
through WRAM for ever.

The power-on fill is worth one paragraph, because it looks like it might be
the lever and is not. Ours is `$55`, whose bit 7 is clear; a fill of `$AA`
would satisfy the terminator by accident. Building with `$AA` was tried: the
loop does exit, and the ROM then runs into a `BRK` at `$00:0000` and stays
there. What is missing is the whole of initialisation, not one byte of it.
`$55` stays, since a fill that makes a broken ROM appear to start is worse
than one that does not.

---

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
