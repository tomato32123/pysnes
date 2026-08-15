"""Resolve which ROM the tools should run against.

Order: an explicit argument, then $PYSNES_ROM, then a single .smc/.sfc found in
a `roms/` directory next to the project.  Keeping this out of the tools means
no local path is baked into the repository.
"""
import glob
import os
import sys

NL = chr(10)
NO_ROM = 77          # the exit code tools/runtests.py reads as a skip

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rom_path(explicit=None, quiet=False):
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

    # Exit 77 rather than 1: without a ROM these tools cannot run at all,
    # which is not the same as failing.  The test runner reads it as a skip,
    # so a machine with no ROM on it still gets a green suite.  A caller that
    # has something to do without a ROM passes quiet=True and catches it: the
    # message is for a tool that is about to stop, not for one carrying on.
    if not quiet:
        sys.stderr.write(
            "no ROM given.  Pass a path as the first argument, set PYSNES_ROM, or"
            + NL + "put a single .smc/.sfc into %s" % os.path.join(ROOT, "roms") + NL)
    raise SystemExit(NO_ROM)


def material_root():
    """Where this machine keeps its test cartridges.

    $PYSNES_ROMS, or a `.romsdir` file beside the project holding the path,
    or roms/ if neither says otherwise.  The file is deliberately not
    tracked: a path that exists on one machine does not belong in a
    repository, and writing one in is how a suite quietly stops being
    runnable anywhere else.  That is not hypothetical -- the clock test
    failed on the first ARM machine it ever ran on, for exactly this, and
    read as a porting fault until the reason was looked at.
    """
    env = os.environ.get("PYSNES_ROMS")
    if env:
        return env
    marker = os.path.join(ROOT, ".romsdir")
    if os.path.exists(marker):
        with open(marker) as fh:
            said = fh.read().strip()
        if said:
            return said
    return os.path.join(ROOT, "roms")


ROMS = material_root()


def find_named(*names):
    """Find one particular cartridge by name, or return None.

    Some hardware can only be exercised by the software written for it: a
    clock chip that one game reads, a coprocessor's own self-test program.
    A test for that needs a named cartridge rather than any cartridge, and
    the name is the only part of it that can live in a repository.

    Looked for in $PYSNES_ROMS, walked as a directory tree, and then in
    roms/ beside the project.  Returning None rather than raising lets the
    caller exit NO_ROM, so a machine without that cartridge records a skip
    instead of a failure -- which is the difference between "this was not
    checked here" and "this is broken here", and they are not the same
    news.
    """
    wanted = {n.lower() for n in names}
    roots = [p for p in (material_root(), os.path.join(ROOT, "roms"))
             if p and os.path.isdir(p)]
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if name.lower() in wanted:
                    return os.path.join(dirpath, name)
    return None


def any_rom():
    """One cartridge, the same one every time, for a test that needs a
    cartridge rather than a particular cartridge.

    Save states and rewind have to be checked against something real, and
    it does not matter what -- but it does matter that it is the same thing
    on every run, or a failure cannot be reproduced.  So this is the first
    name in sorted order under the material root, which is stable as long
    as the collection is.

    Returns None when there is nothing to pick, so the caller can skip.
    """
    root = material_root()
    if not os.path.isdir(root):
        return None
    found = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.lower().endswith((".smc", ".sfc")):
                found.append(os.path.join(dirpath, name))
    return sorted(found)[0] if found else None


def from_argv(index=1, quiet=False):
    """Take argv[index] as the ROM if it looks like one, else fall back."""
    if len(sys.argv) > index and sys.argv[index].lower().endswith((".smc", ".sfc")):
        return _check(sys.argv.pop(index))
    return rom_path(quiet=quiet)


def _check(path):
    if not os.path.exists(path):
        raise SystemExit("no such ROM: %s" % path)
    return path
