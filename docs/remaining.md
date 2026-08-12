# What is left, and what it would take

`roadmap.md` is the checklist. This is the working brief behind it: for each
thing still open, what it actually is, where in the code it goes, how you
would know you got it right, and what — if anything — makes it impossible
today. Written so it can be picked up cold.

As of this writing: **39 done, 6 partial, 6 untouched** of 52 items. The
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

There is now one thing that partly substitutes for it, and it is worth
knowing which parts. blargg's SPC test ROMs are here (see item 10), and they
are a real external authority — but only over the APU. Everything to do with
the CPU's and the PPU's timing is still checked against nothing but this
project's own reading of the documentation.

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

With that, **three of the four test ROMs pass** — `spc_smp` in all sixteen
of its sections, `spc_mem_access_times`, and `spc_timer`. Only the DSP echo
test is left, and it belongs to item 2 rather than here.

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

### 2. DSP as a 32-step pipeline

*Where*: `snes/apu.pyx`, `DSP.tick`, which does a whole sample in one lump.

The real chip walks 32 steps per sample, and several things are only correct
in terms of those steps: KON and KOF latch on a two-sample boundary, ENDX is
set and cleared at particular steps, ENVX and OUTX read mid-sample give the
old or the new value depending on where you are, and the echo has a fixed
latency that falls out of the step order rather than being applied to it.

*How you would know*: `tests/test_dsp.py` already checks output against an
independent Python decoder — extend that to the register reads. Properly,
this wants the SPC700 test ROMs (below).

*Why it is last*: the audible difference is close to nil, the observable
difference is in register reads few games make, and the risk to working
audio is real. Highest effort, lowest confirmed payoff, of anything here.

### 3. The real gaussian table

*Where*: `snes/apu.pyx`, built at startup with σ = 0.628073 and normalised in
groups of four to 2048.

The chip has 512 specific values in a mask ROM. The generated table is close
but not identical, and the difference is a fraction of a bit of interpolation
noise. **This one cannot be done from reasoning** — the table has to be
copied from a dump or from another emulator's source. Do not attempt to
reconstruct it by ear or by curve fitting; a table that is nearly right is
indistinguishable from one that is right, right up until it is not.

### 4. `$2140-$2143` access timing

*Where*: `snes/bus.pyx` `read_mmio`/`write_mmio`, which run the APU up to the
current master clock and then read the port.

The port is a latch clocked by the SPC700, not by the console, so a console
read landing inside the SPC700's write window can see either byte. Modelling
it needs the item above (bus-access timing) to say where that window is.

### 5. Half-height objects (`$2133` bit 1)

*Where*: `snes/ppu.pyx`, `begin_line`, which currently evaluates sprites
against the display row and says so in a comment.

Left undone deliberately. There are two readings of what the bit does — that
sprites halve in height on screen, or that they take alternate source lines
per field — and no way to choose between them here: nothing in the library
turns it on, and it only means anything in interlace, which nothing turns on
either. Guessing would produce a confident-looking implementation with a
coin-flip chance of being backwards. Wait for a reference.

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

### 7. SPC7110, OBC1, RTC

Same category as S-DD1 — documented behaviour, nothing hidden inside — but
nothing in the local library needs them, so they would be written blind.
Lower priority than S-DD1 for exactly that reason.

### 8. SuperFX

*Where*: new board, plus a second `AddressSpace`.

Structurally the easiest of the big ones now, because `snes/space.pyx`
already exists: the SA-1 work proved that a second processor can be given
its own map without duplicating a core. SuperFX needs its own instruction
set rather than reusing the 65816, which is the bulk of the work — 500-odd
opcodes across the ALT1/ALT2 prefix modes — plus the plot/pixel cache unit,
which is where the subtlety lives.

*Blocked on*: nothing. Just size. No title in the local library uses it, so
verification would need a ROM that is not here.

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
| `spc_dsp6.sfc` | the echo unit: basics, ESA and EDL changes | **Failed 02** |

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
```

Two habits worth keeping. `batchtest` judges on the best frame of a run, not
the last — it used to judge on the last, and reported working games as black
because it caught them mid-fade. And when a golden trace changes, re-record
it deliberately (`difftrace record`) after looking at the diff, never
reflexively; the whole point is that a moved cycle has to be noticed.
