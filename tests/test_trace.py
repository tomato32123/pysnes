"""Compare the core's instruction traces against the ones committed here.

This does not say the emulator is right.  Only a reference emulator can say
that, and `tools/difftrace.py diff` is there for when one is to hand.  What
this does say is that nothing about the CPU's behaviour or its timing changed
without someone meaning it -- a golden trace carries the master clock of every
instruction, so a cycle that moves shows up as a diff rather than as a game
that stopped working three weeks later.

Re-baseline deliberately, never reflexively:

    python tools/difftrace.py record
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools import difftrace


def main():
    print("golden traces")
    return difftrace.cmd_check(sorted(difftrace.PROGRAMS), difftrace.ALL_FIELDS)


if __name__ == "__main__":
    sys.exit(main())
