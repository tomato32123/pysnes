# Running this on a phone, before writing an app

The Android question is one question, and it is not "can it be packaged".
It is **can an ARM processor run a frame in under 16.67 ms**, because
everything else follows from the answer. This machine does it in 4.70 ms,
three and a half times over — but that is a desktop x86, and the number says
nothing about a phone.

The measurement needs no app. No display, no sound, no touch controls, no
APK. The core has no desktop dependencies at all: only `snes/gamepad.py` and
`snes/audioout.py` touch pygame, and neither is imported by the emulator.
That was checked rather than assumed — the emulator runs a game to a picture
with pygame made unavailable.

## What to install

Termux, from F-Droid. Then:

```sh
pkg install python clang git
pip install cython setuptools
```

That is the whole list. The build wants Cython and setuptools; the tests and
the benchmark want nothing else. No numpy, no pygame.

## Getting the code and a ROM across

Either clone it, if the repository is reachable from the phone:

```sh
git clone <this repository>
cd pysnes
```

or copy the directory over by USB, which avoids any question of access. A
ROM has to come across too — any commercial cartridge dump will do, and the
timing hardly varies between them.

## Running it

```sh
sh tools/armcheck.sh /path/to/a/rom.smc
```

It builds the cores, runs the test suite, and then times three benchmark
runs.

## Reading the answer

Take the **best** of the three timings. A phone shares its cores with
everything else it is doing, so the slowest reading is measuring the
neighbours rather than the emulator. (The same trap caught a measurement on
the desktop: 9.33 ms while three other processes were busy, against 4.70 ms
on a quiet machine. One measurement is not a measurement.)

| best of three | what it means |
| --- | --- |
| under 10 ms | room to spare. The display, sound and touch controls still have to fit alongside it, but there is space for them |
| 10 to 16 ms | tight. Those three will probably push it past the line |
| over 16.67 ms | optimisation comes first. Building an app around it would be work thrown away |

## The test suite matters as much as the timing

Step 3 is not a formality. Moving to a different processor is exactly when
latent faults surface: an integer that happened to be the right width on
x86, a right shift whose sign was never in question, an access that happened
to be aligned. The cores are Cython, which becomes C, so all of those are
possible here.

**Anything that fails in step 3 is a real defect** — one that exists on the
desktop too and simply never showed itself. It is not an Android problem and
should not be treated as one. It also cannot be found on the machine this
was written on, which makes the phone a piece of verification apparatus
rather than a deployment target.

## What comes after, in order

1. Measure. Nothing else until there is a number.
2. If it is slow, optimise. The profiler is `tools/frameprof.py`, and the
   last round of it took a frame from 11.4 ms to 4.6.
3. If it is fast enough, write the outer layer: display, sound, input, ROM
   picking. The emulator itself needs no changes — the same `.pyx` sources
   build for both machines, and only the toolchain differs.
4. Package.

Doing 3 before 1 risks throwing all of 3 away.
