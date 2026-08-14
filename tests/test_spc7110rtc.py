"""The clock on an SPC7110 cartridge, driven the way a game drives it.

Only Tengai Makyou Zero has this part, and it does not read the clock in
the first minute after boot -- so waiting for the game to exercise it is
not a test, it is a hope.  Instead a console program here runs the
protocol itself: raise the chip select, say whether this exchange reads
or writes, give a register number, and then take the nibbles as they step
along.

What that checks is everything except the passage of time: the three
addresses, the state machine, the register file, and that the digits the
chip hands back are the digits of this machine's clock.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System
from tools.romarg import find_named, NO_ROM

# This one cannot be assembled here: the readings come from the check
# program the chip's makers put in the cartridge, so it has to be that
# cartridge.  Set PYSNES_ROMS to a directory holding it, or drop it into
# roms/ beside the project.
ROM = find_named("Tengai Makyou Zero (Japan).sfc",
                 "Tengai Makyou Zero (Japan).smc")

FAILURES = []


def check(what, got, want, fmt="%s"):
    if got != want:
        FAILURES.append("%s: got %s, want %s" % (what, fmt % got, fmt % want))


def board():
    machine = System(ROM)
    for _ in range(4):
        machine.run_frame()
    return machine.bus.board


def read_all(chip):
    """Raise the chip select, ask to read from register 0, take sixteen."""
    chip.rtc_drive(0x4840, 1)
    chip.rtc_drive(0x4841, 0x0C)
    chip.rtc_drive(0x4841, 0x00)
    out = [chip.rtc_drive(0x4841) for _ in range(16)]
    chip.rtc_drive(0x4840, 0)
    return out


def test_the_clock_hands_back_the_time_it_is():
    chip = board()
    check("the board knows it has a clock", "RTC" in chip.describe(), True)
    before = time.localtime()
    r = read_all(chip)
    check("every register is one nibble", max(r) <= 15, True)

    check("year", r[11] * 10 + r[10], before.tm_year % 100, "%d")
    check("month", (r[9] & 1) * 10 + r[8], before.tm_mon, "%d")
    check("day", (r[7] & 3) * 10 + r[6], before.tm_mday, "%d")
    # The chip counts weekdays from Sunday; Python counts them from Monday.
    check("weekday", r[12] & 7, (before.tm_wday + 1) % 7, "%d")
    # Twelve-hour form until a game sets the twenty-four-hour bit.
    check("hour", (r[5] & 3) * 10 + r[4], before.tm_hour % 12 or 12, "%d")
    check("minute", (r[3] & 7) * 10 + r[2], before.tm_min, "%d")


def test_the_twenty_four_hour_bit_changes_the_hours_reported():
    chip = board()
    chip.rtc_drive(0x4840, 1)
    chip.rtc_drive(0x4841, 0x03)          # a write exchange
    chip.rtc_drive(0x4841, 0x0F)          # at register 15
    chip.rtc_drive(0x4841, 0x04)          # bit 2: the twenty-four-hour clock
    chip.rtc_drive(0x4840, 0)
    r = read_all(chip)
    check("hour in twenty-four-hour form", (r[5] & 3) * 10 + r[4],
          time.localtime().tm_hour, "%d")


def test_a_register_written_reads_back():
    chip = board()
    chip.rtc_drive(0x4840, 1)
    chip.rtc_drive(0x4841, 0x03)
    chip.rtc_drive(0x4841, 0x0D)          # register 13, which holds no digit
    chip.rtc_drive(0x4841, 0x0A)
    chip.rtc_drive(0x4840, 0)
    r = read_all(chip)
    check("register 13 after writing $A", r[13], 0x0A, "$%X")


def test_the_status_register_says_a_transfer_may_happen():
    chip = board()
    check("status", chip.rtc_drive(0x4842) & 0x80, 0x80, "$%02X")


def test_nothing_is_handed_over_without_a_command():
    """Reading the data port outside an exchange must not walk the
    registers: the state machine has to have been started."""
    chip = board()
    check("no answer before a command", chip.rtc_drive(0x4841), 0, "%d")


def test_the_cartridges_own_check_program_gets_its_rollover():
    """The strongest evidence available for this chip.

    Tengai Makyou Zero carries a hardware self-test written by the people
    who built the cartridge.  Its clock section sets 23:59:59 on the last
    day of '99 with weekday 6, lets the clock run, stops it and reads back
    -- so what it is looking for is the roll across midnight, the month,
    the year and the century at once, with the weekday carried by one.

    Getting this wrong is what "RTC TIME  NG" on its screen means, and it
    said exactly that until the weekday stopped being worked out from the
    date: the chip does not know what day of the week a date falls on, it
    only counts.
    """
    machine = System(ROM)
    for _ in range(900):
        machine.run_frame()
    for _ in range(4):
        for button in (0x80, 0x1000):          # A, then start
            machine.set_pad(0, button)
            for _ in range(10):
                machine.run_frame()
            machine.set_pad(0, 0)
            for _ in range(60):
                machine.run_frame()

    got = [v for off, write, v in machine.bus.board.rtc_exchanges if not write]
    check("the check program reached its clock test", len(got) >= 13, True)
    # second, minute, hour, day, month, year, weekday -- all rolled over.
    check("what the cartridge reads back", got[:13],
          [0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0])


def main():
    if ROM is None:
        sys.stderr.write("Tengai Makyou Zero is not on this machine; set "
                         "PYSNES_ROMS to where it is" + chr(10))
        return NO_ROM
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (name, type(exc).__name__, exc))
        print("  %-58s %s" % (name, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("the cartridge clock reads back the time")
    return 0


if __name__ == "__main__":
    sys.exit(main())
