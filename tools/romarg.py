"""Resolve which ROM the tools should run against.

Order: an explicit argument, then $PYSNES_ROM, then a single .smc/.sfc found in
a `roms/` directory next to the project.  Keeping this out of the tools means
no local path is baked into the repository.
"""
import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rom_path(explicit=None):
    if explicit:
        return _check(explicit)

    env = os.environ.get("PYSNES_ROM")
    if env:
        return _check(env)

    found = []
    for pattern in ("*.smc", "*.sfc", "*/*.smc", "*/*.sfc"):
        found += glob.glob(os.path.join(ROOT, "roms", pattern))
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        raise SystemExit("several ROMs in roms/; pass one explicitly:\n  "
                         + "\n  ".join(sorted(found)))

    raise SystemExit(
        "no ROM given.  Pass a path as the first argument, set PYSNES_ROM, or\n"
        "put a single .smc/.sfc into %s" % os.path.join(ROOT, "roms"))


def from_argv(index=1):
    """Take argv[index] as the ROM if it looks like one, else fall back."""
    if len(sys.argv) > index and sys.argv[index].lower().endswith((".smc", ".sfc")):
        return _check(sys.argv.pop(index))
    return rom_path()


def _check(path):
    if not os.path.exists(path):
        raise SystemExit("no such ROM: %s" % path)
    return path
