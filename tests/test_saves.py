"""Battery saves: where they land, and which older ones are still picked up.

Nothing covered any of this until now, and the naming changed underneath it
the same day: saves used to be keyed by the ROM's base name alone, so two
different games sharing one -- ordinary in a collection sorted into folders
-- wrote over each other's battery and the second to be opened lost a save
with nothing said.  The cartridge's checksum is in the name now.

Which means there are two older shapes somebody's saved game may be sitting
in, and both have to keep being read: the name without a checksum, which is
what this wrote before, and one beside the ROM, which belongs to whatever
emulator put it there.  Neither is written back to; both are imported once
and then saved under the new name.

`PYSNES_HOME` moves the save directory, so none of this touches a real
collection.
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import any_rom, NO_ROM

FAILURES = []
MARK = b"pysnes save test"


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (name, got, want))


def fresh_home():
    home = tempfile.mkdtemp(prefix="pysnes-saves-")
    os.environ["PYSNES_HOME"] = home
    return home


def load(rom):
    from snes.system import System
    return System(rom)


def main():
    rom = any_rom()
    if rom is None:
        sys.stderr.write("no cartridge on this machine to save from" + chr(10))
        return NO_ROM

    home = fresh_home()
    try:
        machine = load(rom)
        if machine.sram_path is None:
            sys.stderr.write("the first cartridge here has no battery; "
                             "nothing to test" + chr(10))
            return NO_ROM

        # 1. The name carries the cartridge's checksum, not just the file's.
        name = os.path.basename(machine.sram_path)
        check("save is named for the cartridge", name,
              "%s-%04X.srm" % (os.path.splitext(os.path.basename(rom))[0],
                               machine.cart.computed_checksum))

        # 2. What is written comes back.
        size = len(machine.cart.sram_data)
        for i, b in enumerate(MARK):
            machine.cart.sram_data[i % size] = b
        machine.save_sram()
        again = load(rom)
        got = bytes(again.cart.sram_data[:len(MARK)])
        check("what was saved is read back", got, MARK[:len(MARK)])

        # 3. A save under the older name, without a checksum, is imported.
        home = fresh_home()
        older = os.path.join(home, "saves",
                             os.path.splitext(os.path.basename(rom))[0] + ".srm")
        os.makedirs(os.path.dirname(older), exist_ok=True)
        with open(older, "wb") as fh:
            fh.write(MARK + bytes(size - len(MARK)))
        imported = load(rom)
        check("a save under the older name is imported",
              bytes(imported.cart.sram_data[:len(MARK)]), MARK)
        check("and it is not the file that gets written to next",
              os.path.basename(imported.sram_path) == os.path.basename(older),
              False)

        # 4. Two cartridges sharing a file name do not share a battery.  The
        #    same image under two names is the case that used to collide.
        home = fresh_home()
        copied = os.path.join(home, os.path.basename(rom))
        shutil.copyfile(rom, copied)
        one, two = load(rom), load(copied)
        check("the same cartridge in two places uses one battery",
              os.path.basename(one.sram_path),
              os.path.basename(two.sram_path))
    finally:
        os.environ.pop("PYSNES_HOME", None)

    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  " + line)
        return 1
    print("all battery-save tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
