#!/bin/sh
# Build the cores on this machine, prove they are correct, then time them.
#
# Written for a phone, which means written for a person who cannot easily
# copy forty lines of terminal output off it.  Everything goes into a file
# on the shared storage, and what reaches the screen is a handful of lines
# short enough to read out loud.
#
# The tests run before the benchmark on purpose.  Moving to a different
# processor is when latent faults surface -- an integer that was the right
# width on x86, a `char` that was signed there and is not here, an access
# that happened to be aligned.  Anything that fails is a real defect, not an
# Android problem, and it cannot be found on a desktop.
#
#   sh tools/armcheck.sh /path/to/a/rom.smc

ROM="$1"
OUT="$HOME/storage/shared/pysnes-armcheck.txt"
[ -d "$HOME/storage/shared" ] || OUT="./pysnes-armcheck.txt"

if [ -z "$ROM" ]; then
    echo "usage: sh tools/armcheck.sh <rom>"
    exit 1
fi

{
    echo "== machine"
    uname -m
    python -c "import sys; print('python', sys.version.split()[0])"
    echo
    echo "== build"
    python build.py 2>&1
    echo
    echo "== tests"
    python tools/runtests.py 2>&1
    echo
    echo "== speed"
    python tools/bench.py "$ROM" 2>&1
    python tools/bench.py "$ROM" 2>&1
    python tools/bench.py "$ROM" 2>&1
} > "$OUT" 2>&1

# ---- what reaches the screen -------------------------------------------
#
# The test runner already works out whether the failures are one fault or
# several and says so in plain words, so the summary here is its verdict
# verbatim -- everything from the end of the module list up to the first
# full transcript -- rather than a second, worse diagnosis grepped out of
# the same file.
echo
echo "---------------- read this out ----------------"
sed -n '/^== tests/,/^=== /p' "$OUT" | grep -v "PASS$" | grep -v "^=== " | \
    grep -v "^== tests" | sed '/^$/d' | head -14

grep -o "[0-9.]* ms/frame" "$OUT" | sort -n | head -1 | sed 's/^/fastest frame: /'
echo "-----------------------------------------------"
echo
echo "full log: $OUT"
echo "(that file is in the phone's own storage, so it can be sent"
echo " by whatever is convenient -- no copying from the terminal)"
