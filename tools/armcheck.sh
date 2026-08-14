#!/bin/sh
# Build the cores on this machine, prove they are correct, then time them.
#
# Written for a phone.  The question it answers is whether this emulator can
# hold 60 frames a second on the hardware people actually own, and the answer
# is a number rather than an opinion: a frame's budget is 16.67 ms.
#
# It runs the tests before the benchmark on purpose.  Moving to a different
# processor is when latent faults surface -- an integer that was the right
# width on x86, a shift whose sign was never in question, an access that
# happened to be aligned.  Anything that fails here is a real defect, not an
# Android problem, and it cannot be found on the machine this was written on.
#
#   sh tools/armcheck.sh /path/to/a/rom.smc

set -e
ROM="$1"

if [ -z "$ROM" ]; then
    echo "usage: sh tools/armcheck.sh <rom>"
    echo "any commercial cartridge dump will do; the timing barely varies"
    exit 1
fi

echo "== 1. what this machine is"
uname -m
python -c "import sys; print('python', sys.version.split()[0])"

echo
echo "== 2. building the cores"
python build.py

echo
echo "== 3. is it still correct here?"
python tools/runtests.py

echo
echo "== 4. how fast is it?"
echo "   a frame must finish inside 16.67 ms to hold 60 per second"
python tools/bench.py "$ROM"
python tools/bench.py "$ROM"
python tools/bench.py "$ROM"

echo
echo "Take the best of the three: a phone shares its cores with everything"
echo "else running, and the slowest reading measures the neighbours."
echo
echo "  under 10 ms   room to spare -- the display, sound and touch controls"
echo "                still have to fit alongside it"
echo "  10 to 16 ms   tight; those three will probably push it over"
echo "  over 16.67 ms optimisation comes before any app work"
