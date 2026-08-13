"""The SuperFX, driven from a 65816 program on a cartridge that says it has one.

The chip is a whole second processor, so most of what can go wrong is in the
instruction set.  These tests run GSU programs the way a game does: point r15
at the code, start the chip by writing the high half of r15, wait for it to
stop, then read the answer out of its registers.

The waiting is the awkward part, and it is awkward on hardware too.  While the
chip is running it has the cartridge's ROM, and the console reading ROM gets a
sixteen-byte vector table instead -- including when the console is reading ROM
to *fetch its own instructions*.  So the routine that starts the chip and waits
for it cannot itself live in ROM.  Star Fox copies its main loop into work RAM;
these tests copy a small resident routine into $00:0300 and call it there.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.testrom import assemble_image, WRAM_BASE, RESULT_ADDR, DONE_ADDR
from snes.system import System

SUPERFX_CHIPSET = 0x13
IMAGE = 0x100000                     # 1 MB, the size Star Fox is
GSU_AT = 0x8000                      # ROM offset of the GSU program: $01:8000
RESIDENT = 0x0300                    # where the wait routine is copied to
FAILURES = []


def build(source, gsu_code):
    """A cartridge with `source` for the console and `gsu_code` for the chip.

    The chip reads $00-$3f:8000-ffff as one run of bytes from the start of the
    ROM, exactly as the console does, so the console's own 32 KB bank is the
    first one and the GSU program goes in the second: bank $01, offset $8000.
    """
    image, _labels = assemble_image(source, chipset=SUPERFX_CHIPSET)
    rom = bytearray(IMAGE)
    rom[0:len(image)] = image
    rom[GSU_AT:GSU_AT + len(gsu_code)] = gsu_code
    return bytes(rom)


def with_resident(resident, after):
    """Wrap `resident` so it runs from WRAM and `after` runs once it returns.

    `resident` must be relocatable -- branches and absolute addresses only, no
    reference to its own labels -- because it is assembled in ROM at one
    address and executed at another.
    """
    return """
        rep #$10
        sep #$20
        ldx #$0000
__copy: lda __resident,x
        sta $0300,x
        inx
        cpx #$0040
        bne __copy
        jsr $0300
%s
        bra __past
__resident:
%s
        rts
__past:
""" % (after, resident)


# Start the chip at $01:8000 and wait for it to stop.  Runs from WRAM.
START_AND_WAIT = """
        lda #$1c                        ; screen mode: ROM and RAM to the chip
        sta $303a
        lda #$01
        sta $3034                       ; program bank 1
        lda #$00
        sta $301e                       ; r15 low
        lda #$80
        sta $301f                       ; r15 high -- and this starts it
__wait: lda $3030
        and #$20
        bne __wait
"""

# Once the chip has stopped the console has its ROM back, so this part can run
# from ROM: copy r0 through r3 out to where a test can read them.
COPY_REGISTERS = "".join(
    "        lda $30%02x\n        sta result+%d\n" % (i, i) for i in range(8))


def run(source, gsu_code, max_frames=30):
    machine = System(rom_data=build(source, gsu_code))
    if machine.bus.board.name != "SuperFX":
        raise AssertionError("board is %s" % machine.bus.board.name)
    for _ in range(max_frames):
        machine.run_frame()
        if machine.bus.read(WRAM_BASE + DONE_ADDR):
            break
    else:
        raise AssertionError("the program never finished")
    return machine


def run_gsu(gsu_code):
    return run(with_resident(START_AND_WAIT, COPY_REGISTERS), gsu_code)


def gsu_result(machine, reg):
    lo = machine.bus.read(WRAM_BASE + RESULT_ADDR + reg * 2)
    hi = machine.bus.read(WRAM_BASE + RESULT_ADDR + reg * 2 + 1)
    return lo | (hi << 8)


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got $%04X, want $%04X" % (name, got, want))


def test_the_chip_runs_and_stops():
    """iwt r0,#$1234 then stop.  If the chip never clears the go flag the
    console waits for ever, and a game that starts it never draws again."""
    machine = run_gsu(bytes([
        0xF0, 0x34, 0x12,               # iwt r0, #$1234
        0x00,                           # stop
    ]))
    check("r0", gsu_result(machine, 0), 0x1234)


def test_arithmetic_and_the_prefixes():
    """add, sub and the register prefixes.  FROM and TO pick which register an
    instruction reads and writes, so the same opcode means different things
    depending on what came before it."""
    machine = run_gsu(bytes([
        0xF0, 0x0A, 0x00,               # iwt r0, #$000a
        0xF1, 0x03, 0x00,               # iwt r1, #$0003
        0xB0,                           # from r0
        0x11,                           # to r1  -> next op reads r0, writes r1
        0x51,                           # add r1        r1 = r0 + r1 = $0d
        0xB1,                           # from r1
        0x12,                           # to r2
        0x60,                           # sub r0        r2 = r1 - r0 = $03
        0x00,                           # stop
    ]))
    check("r1 after add", gsu_result(machine, 1), 0x000D)
    check("r2 after sub", gsu_result(machine, 2), 0x0003)


def test_jump_names_the_high_registers():
    """$98-$9d are jmp r8 through r13, not jmp r0 through r5.  Getting that
    wrong puts the chip in a loop it cannot leave: Star Fox's first polygon
    frame hangs on `jmp r11` at $01:8199."""
    machine = run_gsu(bytes([
        0xFB, 0x0C, 0x80,               # iwt r11, #$800c   (the target)
        0xF0, 0x01, 0x00,               # iwt r0, #$0001
        0x9B,                           # jmp r11
        0x01,                           # nop  (the delay slot)
        0xF0, 0x99, 0x99,               # iwt r0, #$9999 -- must not run
        0x01, 0x01,                     # padding, to $800c
        0xF1, 0x77, 0x77,               # iwt r1, #$7777
        0x00,                           # stop
    ]))
    check("r0", gsu_result(machine, 0), 0x0001)
    check("r1", gsu_result(machine, 1), 0x7777)


def test_loop_runs_out_of_the_cache():
    """`loop` decrements r12 and branches to r13 while it is not zero.  A loop
    that fits in the 512-byte cache is the whole reason the chip is fast, so
    this also exercises the cache filling and being read back."""
    machine = run_gsu(bytes([
        0xFC, 0x05, 0x00,               # iwt r12, #$0005     the count
        0xFD, 0x09, 0x80,               # iwt r13, #$8009     the top of the loop
        0xF0, 0x00, 0x00,               # iwt r0, #$0000      the accumulator
        0xD0,                           # inc r0              (at $8009)
        0x3C,                           # loop                r12 -= 1, back to r13
        0x01,                           # nop  (the delay slot, run either way)
        0x00,                           # stop
    ]))
    check("r0 after five passes", gsu_result(machine, 0), 0x0005)


def test_the_console_cannot_see_rom_while_the_chip_runs():
    """The cartridge gives the ROM to the chip, and a console read gets the
    sixteen-byte vector table instead.  That is what keeps a game's reset and
    interrupt vectors reachable while the chip has the bus -- and it is why
    the routine doing the reading has to be in RAM."""
    resident = """
        lda #$1c
        sta $303a
        lda #$01
        sta $3034
        lda #$00
        sta $301e
        lda #$80
        sta $301f                       ; the chip is now running
        lda $818004                     ; read ROM while it has it
        sta result+0
__wait: lda $3030
        and #$20
        bne __wait
        lda $818004                     ; and again once it has stopped
        sta result+1
"""
    machine = run(with_resident(resident, ""), bytes([0x01] * 200 + [0x00]))
    while_running = machine.bus.read(WRAM_BASE + RESULT_ADDR + 0)
    afterwards = machine.bus.read(WRAM_BASE + RESULT_ADDR + 1)
    if while_running != 0x04:
        FAILURES.append("ROM read while running gave $%02X, want the vector $04"
                        % while_running)
    if afterwards != 0x01:
        FAILURES.append("ROM read after stopping gave $%02X, want the ROM's $01"
                        % afterwards)


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in tests:
        before = len(FAILURES)
        try:
            fn()
        except Exception as exc:
            FAILURES.append("%s raised %s: %s" % (fn.__name__, type(exc).__name__, exc))
        print("  %-52s %s" % (fn.__name__, "ok" if len(FAILURES) == before else "FAIL"))
    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("all SuperFX tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
