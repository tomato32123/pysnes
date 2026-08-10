# pysnes

A Super Famicom / SNES emulator written in Python, with the hot cores compiled
through Cython. It boots and plays commercial titles at roughly 110 fps — 1.8x real
hardware — with video, input and audio.

```
  65816 S-CPU  ──▶  Bus (memory map, MMIO, DMA/HDMA, timing, IRQ/NMI)
                      ├──▶  S-PPU   (BG modes 0-7, sprites, windows, colour math)
                      └──▶  APU     (SPC700 core + timers) ──▶ S-DSP (8 BRR voices, echo)
```

## What is implemented

**S-CPU (65816)** — all 256 opcodes, every addressing mode, emulation and native
mode with the M/X width flags, decimal-mode ADC/SBC, block moves, and the full
interrupt set (RESET/NMI/IRQ/BRK/COP/ABORT). Timing is bus-access driven: each
access charges the master-clock cost of its address (6/8/12 cycles depending on
region and the FastROM bit) and instructions add internal cycles where the real
core has them, including the indexed page-cross and direct-page penalties.

**Bus** — an 8 KB-granular page table over the 24-bit address space; HiROM,
LoROM and ExHiROM mapping; 128 KB WRAM with its mirrors and the $2180 port;
battery SRAM; open-bus latch; the $2100-$21FF and $4200-$43FF register files;
multiply/divide units; scanline/dot timing driving V-blank, H/V IRQ and auto
joypad read; general DMA and HDMA across all eight channels and all eight
transfer modes.

**S-PPU** — the complete register interface with the hardware's access quirks
(VRAM address remapping and read prefetch, the write-twice scroll latches with
their separate H latch, the OAM byte latch, CGRAM's low/high toggle). The
renderer is per-scanline and covers BG modes 0-7 including mode 7's affine
transform with its wrap/clip modes, 2/4/8 bpp tiles, 8x8 and 16x16 tiles,
mosaic, all sprite sizes with the 32-sprite / 34-tile line limits, both
windows with their four logic combinations, and colour math (add/subtract,
half, fixed colour, sub-screen, and both CGWSEL region selectors).

**APU** — the SPC700 with all 256 opcodes, the three timers with their real
prescalers, the four communication ports, and the 64-byte IPL boot ROM that
runs the upload handshake at reset. The S-DSP decodes BRR samples with all four
filters, runs ADSR and all four GAIN modes, does gaussian interpolation, noise,
pitch modulation, and the 8-tap FIR echo unit writing back into APU RAM.

### Known gaps

* No enhancement chips (SA-1, SuperFX, DSP-1, …). Plain LoROM/HiROM only.
* The DSP interpolation kernel is a generated gaussian rather than a dump of
  the chip's table.  Its width is solved so the peak tap lands on the real
  table's 1305 and each group of four taps sums to 2048, which reproduces the
  published values closely (0, 364, 368, 1308 against 0, 370, 370, 1305) but
  is not bit-exact.
* The DSP is modelled per 32 kHz sample rather than per hardware sub-cycle.
* Multiply/divide results appear immediately instead of after their real delay.
* No interlace or pseudo-hires output; overscan is not extended past 239 lines.

## Compatibility

Boot-tested across a 66-image library with `tools/batchtest.py`, running
each for 2400 frames and checking that something is drawn:

| | count |
| --- | --- |
| boots and draws | 53 |
| needs a coprocessor we do not emulate | 8 |
| open bugs | 5 |

That is 53 of the 58 images needing no coprocessor. The eight remaining
are SA-1 (Super Mario RPG, Kirby Super Deluxe, Jikkyou Oshaberi
Parodius, Mini Yonku Shining Scorpion), S-DD1 (Street Fighter Zero 2)
and DSP-1 (Super Mario Kart).

Give slow starters room: several titles need well over a thousand frames
before they draw anything. Rudra no Hihou, Sim City 2000 and Zero 4
Champ RR all looked dead at 900 frames and were fine at 2400.

Still open: Dragon Ball Z Super Butouden 3, Super Puyo Puyo 2 Remix,
Super Famista 5 (draws early, goes black later), and the SMWREX and Mix
ROM hacks.

## Building

Needs Python 3.8+, Cython, and a C compiler (MSVC Build Tools with the C++
workload on Windows).

```
pip install cython pygame
python build.py            # add --force to rebuild everything, -v for full output
```

`build.py` locates MSVC through `vswhere` and runs the compiler with a clean
environment — a raw MSYS/Git-Bash environment makes `vcvars64.bat` fail
silently, which is why the build is driven from this script rather than calling
`setup.py` directly.

## Running

```
python play.py <rom.smc> [--scale N] [--no-audio]
```

The extension modules only load in the exact CPython minor version they were
built for, and a bare `python` is often a different install (or one without
pygame). `run.cmd` / `run.ps1` probe the interpreters on PATH and use the first
that can import both `snes.system` and `pygame`:

```
.\run.cmd "c:\path\to\rom.smc"
```

Set `PYSNES_PYTHON` to skip the search and name an interpreter directly.

Options: `--scale N` (window size, default 3), `--no-audio`,
`--rewind-seconds N` (default 20, 0 to disable), and `--frames N`
(run headless for N frames then exit, for testing).

| Key | Button |
| --- | --- |
| Arrow keys | D-pad |
| Z / X | B / A |
| A / S | Y / X |
| Q / W | L / R |
| Enter | Start |
| Right Shift | Select |
| Tab (hold) | fast forward |
| Backspace (hold) | rewind |
| F2 / F4 | save / load state |
| F5 | write SRAM now |
| Esc | quit (SRAM is written on exit) |

### Compatibility

Boot-tested across a 66-image library with `tools/batchtest.py`, running
each for 2400 frames and checking that something is drawn:

| | count |
| --- | --- |
| boots and draws | 53 |
| needs a coprocessor we do not emulate | 8 |
| open bugs | 5 |

That is 53 of the 58 images needing no coprocessor. The eight remaining
are SA-1 (Super Mario RPG, Kirby Super Deluxe, Jikkyou Oshaberi
Parodius, Mini Yonku Shining Scorpion), S-DD1 (Street Fighter Zero 2)
and DSP-1 (Super Mario Kart).

Give slow starters room: several titles need well over a thousand frames
before they draw anything. Rudra no Hihou, Sim City 2000 and Zero 4
Champ RR all looked dead at 900 frames and were fine at 2400.

Still open: Dragon Ball Z Super Butouden 3, Super Puyo Puyo 2 Remix,
Super Famista 5 (draws early, goes black later), and the SMWREX and Mix
ROM hacks.

## Building a standalone .exe

```
pip install pyinstaller
pyinstaller pysnes.spec --noconfirm
```

Produces a single `dist/pysnes.exe` (~18 MB) with Python, pygame and the
compiled cores inside. Drag a ROM onto it, or double-click and pick one
from the file dialog. Saves and save states go to a `saves/` folder next
to the executable — not into the temporary unpack directory, which is
deleted on exit.

The cores are Cython extension modules, so PyInstaller's import scanner
cannot see through them; every `snes.*` module is listed explicitly in the
spec. Rebuild the extensions with `build.py` before packaging.

### Gamepads

Controllers are read through SDL's GameController layer, so one mapping
covers Xbox, DualShock, Switch Pro and anything else SDL recognises. Plug
one in and it is picked up, including while the emulator is running; a
second pad becomes controller port 2.

The default layout follows physical positions, not labels — the SNES face
buttons sit a quarter turn round from an Xbox pad:

| SNES | Xbox | position |
| --- | --- | --- |
| B | A | bottom |
| A | B | right |
| Y | X | left |
| X | Y | top |
| L / R | LB / RB | shoulders |
| Start / Select | Menu / View | |
| D-pad | d-pad and left stick | |
| fast forward | right trigger | |
| rewind | left trigger | |

`config/gamepad.json` is written on first run and can be edited. `_default`
applies to every pad; add a section keyed by the controller's name to
override just that model. `SAVESTATE` and `LOADSTATE` are unbound by
default — set them to a button name such as `leftstick` to use them.

```
python tools/padtest.py     # live view of what each button maps to
```

### Rewind

Hold Backspace, or the left trigger, to scrub backwards. Snapshot cost set
the design: a state is 267 KB raw and takes 0.38 ms to build, while zlib
level 1 gets it to 87 KB for 3.4 ms and higher levels buy almost nothing.
Recording every third frame at level 1 costs about 1.4 ms per frame against
a 16.7 ms budget, and twenty seconds of history is roughly 45 MB.

Snapshots are three emulated frames apart, so holding rewind plays back at
3x reverse speed. The framebuffer is part of the state — rewind restores
without rendering, so leaving it out froze the picture while scrubbing.

### ROM formats

Copier headers (512 bytes) are stripped, and block-interleaved dumps are
detected and undone.  Interleaved images hold the odd 32 KB blocks first
and the even ones after, which puts a HiROM game's internal header at
$7FB0 -- the LoROM position -- and is what gives the format away.  The
loader scores the header both ways and keeps whichever looks more
plausible; in a 66-ROM library this recovered six games that had been
booting into garbage.

### PAL

The region comes from the header's country byte.  PAL images run 312 lines
per frame against NTSC's 262, use the 21.28 MHz master clock, and report
50 Hz in STAT78 bit 4.  Without that last bit a European cartridge stops at
its own lockout screen -- Donkey Kong Country was displaying "this game pak
is not designed for use on your Super Famicom" rather than booting.

### Where saves go

Battery saves are written to `saves/<rom name>.srm` inside this project, never
next to the ROM. If no save exists there yet, an existing `.srm` beside the ROM
is read once so an existing save carries over — but that file is never written
to, so another emulator's saves stay intact.

## Layout

| Path | What |
| --- | --- |
| `snes/cart.pyx` | ROM loading, internal-header detection, SRAM |
| `snes/bus.pyx` | address decoding, MMIO, DMA/HDMA, timing, interrupts |
| `snes/cpu.pyx` | the 65816 interpreter |
| `snes/ppu.pyx` | PPU registers and the scanline renderer |
| `snes/apu.pyx` | SPC700 core, timers, and the S-DSP |
| `snes/system.pyx` | the machine: wiring, frame loop, save states |
| `snes/audioout.py` | pygame streaming audio |
| `play.py` | the windowed frontend |
| `snes/gamepad.py` | SDL GameController input |
| `snes/rewind.py` | the rewind ring buffer |
| `tools/` | disassembler, tracer, screenshot, benchmark, soak test |
| `docs/android.md` | why the Android port is parked, and what it needs |

`tools/gen_state.py` generates the save-state serialisers from one field list
per class, so the save and load halves cannot drift apart. Re-run it and
rebuild after adding a field to any core.

## Tools

Each tool takes the ROM as its first argument, or reads `$PYSNES_ROM`, or
picks up a single image dropped into `roms/`.

```
python tools/trace.py <rom> [n]      # disassembled execution trace from reset
python tools/screenshot.py 300 600   # render frames to shots/frameNNNN.png
python tools/bench.py 1600 300       # frames per second after a warm-up
python tools/playtest.py             # scripted run from boot into the game
python tools/soak.py 30000           # long run with random input
python tools/batchtest.py <dir>      # boot every ROM in a tree, tabulate
python tools/whystuck.py <rom>       # why a ROM shows no picture
python tools/probe.py 3000000        # raw instruction throughput + hot PCs
python tests/test_cart.py            # header parsing and ROM mirroring
python tests/test_state.py           # save-state determinism
python tests/test_rewind.py          # rewind accuracy, bounds and cost
python tests/test_dsp.py             # DSP against an independent BRR decoder
python tools/dumpwav.py <rom> 15     # record 15 s of audio to shots/audio.wav
python tools/frameprof.py 900        # per-stage frame timing, with percentiles
```
