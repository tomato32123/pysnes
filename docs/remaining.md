# What is left, and what it would take

`roadmap.md` is the checklist. This is the working brief behind it: for each
thing still open, what it actually is, where in the code it goes, how you
would know you got it right, and what — if anything — makes it impossible
today. Written so it can be picked up cold.

As of this writing: **36 done, 6 partial, 9 untouched** of 52 items. The
66-ROM local library boots 61 titles; the five that do not are listed at the
end with what is known about each.

---

## First, the thing that shapes everything else

**There is no reference emulator on this machine.** No bsnes, no ares, no
Mesen. That single absence is why six items are "partial" rather than done,
and it is worth understanding what it costs before reading the rest.

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

Note the two entries against `Mix.smc`: it is the only title in the library
using direct colour or the forced-black region, and it is also one of the
three that render nothing. That is a lead, not a coincidence worth ignoring.

---

## The nine untouched items

### 1. SPC700 bus-access timing

*Where*: `snes/apu.pyx`, the opcode dispatch.

Today each opcode charges a flat cycle count from a table. The totals are
right; what is missing is *when within the opcode* each access happens. That
only becomes observable through `$2140-$2143`, where the console and the
SPC700 hand bytes to each other and the order of a read against a write
decides who sees what.

*How you would know*: the CPU already charges per access (`snes/cpu.pyx`),
and the same shape applies. A test would drive a handshake from both sides
and assert the byte each sees, the way `test_timing.py` does for DMA.

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

### 6. S-DD1

*Where*: new `snes/sddi.pyx` alongside `snes/sa1.pyx`, registered in
`snes/board.pyx`.

A decompressor on the cartridge. **No firmware**: it is an arithmetic
decoder with a documented algorithm, so unlike DSP-1 it can be written.

*Why it is next in line*: Street Fighter Zero 2 is in the library, renders
nothing today, and would go from a black screen to a working game. That
makes it the only remaining coprocessor with a verification target already
to hand.

*Shape*: mapper registers at `$4800-$4807`, four decompression contexts, a
bit-serial arithmetic decoder feeding DMA. The board layer already supports
everything needed — see `SA1.classify` returning `PK_DEVICE` and the bus
routing unclaimed `$2000-$5FFF` out to the cartridge.

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

### 10. SPC700 and DSP test ROMs

These exist publicly and would settle items 1, 2 and 4 at a stroke. They are
not in this repository and should not be committed to it. Fetching them is a
decision for whoever owns the project.

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

## The five titles that do not render

| title | status | what is known |
|---|---|---|
| Street Fighter Zero 2 | black | S-DD1, not implemented. Expected. |
| Super Mario Kart | flat | DSP-1, needs firmware not present. Expected. |
| `Mix.smc` | black | **Unexplained.** The only title using direct colour and the forced-black region. Start here. |
| `SMWREX.smc` | black | Unexplained. Appears to be a Super Mario World hack; may be a bad or modified image. Check the header and checksum first. |
| Kunio-kun no Dodge Ball | flat (2 colours) | **Unexplained.** Fills the screen, so it is running; something about the palette or colour math. |

`Mix.smc` and Kunio-kun are the two worth chasing: both are ordinary LoROM
cartridges with no coprocessor, so whatever is wrong is wrong in the core.

---

## How to verify anything here

```
python build.py                       # the cores are Cython; rebuild after edits
python tools/runtests.py              # nine modules; ROM-dependent ones skip
python tools/batchtest.py <rom-dir>   # boots a library, best frame per title
python tools/featureprobe.py <dir>    # which features anything actually uses
python tools/difftrace.py check       # committed traces, cycle for cycle
```

Two habits worth keeping. `batchtest` judges on the best frame of a run, not
the last — it used to judge on the last, and reported working games as black
because it caught them mid-fade. And when a golden trace changes, re-record
it deliberately (`difftrace record`) after looking at the diff, never
reflexively; the whole point is that a moved cycle has to be noticed.
