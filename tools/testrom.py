"""Build and run test ROMs.

A test is a piece of 65816 assembly.  It is wrapped in a real LoROM image with
a valid header and vectors, loaded through the ordinary cartridge path, and run
until it signals completion.  Results are written to WRAM and read back here,
so a test asserts on values the emulated program actually computed.

    from tools.testrom import run

    r = run('''
        lda #$41
        sta result+0
    ''')
    assert r[0] == 0x41

`result` is a label the prelude defines, and `r[i]` reads the byte at
`result + i`.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.asm65816 import Assembler

BANK_SIZE = 0x8000              # one LoROM bank of code
IMAGE_SIZE = 0x10000            # the loader rejects anything smaller
RESULT_ADDR = 0x4000            # results live at $7E4000
DONE_ADDR = 0x4FFF              # $7E4FFF
WRAM_BASE = 0x7E0000

PRELUDE = """
        .org $8000
__entry:
        sei
        clc
        xce                             ; native mode
        rep #$30
        ldx #$1FFF
        txs
        lda #$0000
        tcd                             ; direct page at $0000
        sep #$30
        phk
        plb                             ; data bank = program bank
        ; WRAM powers up filled, so clear the area tests report through.
        ; Without this an unwritten slot reads as the fill pattern and a test
        ; cannot tell "nothing happened" from "something wrote that value".
        rep #$10
        sep #$20
        lda #$00
        ldx #$0100
__clr:  dex
        sta $7E4000,x
        cpx #$0000
        bne __clr
        sta $7E4FFF                     ; and the completion flag
        sep #$30
        jmp __main
__nmi:  rti
__irq:  rti
__main:
"""

EPILOGUE = """
__finish:
        sep #$20
        lda #$01
        sta $7E4FFF                     ; tell the harness we are done
__hang: bra __hang
"""


def assemble_image(source, title="PYSNES TEST"):
    """Assemble `source` inside the prelude and wrap it in a LoROM image."""
    asm = Assembler()
    # `result` is where tests leave their answers; predefining it lets the
    # assembly refer to it by name.
    asm.labels["result"] = WRAM_BASE + RESULT_ADDR
    code = asm.assemble(PRELUDE + source + EPILOGUE, origin=0x008000)
    labels = asm.labels

    rom = bytearray(IMAGE_SIZE)
    for addr, byte in code.items():
        off = addr - 0x008000
        if not 0 <= off < BANK_SIZE:
            raise ValueError("code at $%06X is outside the image" % addr)
        rom[off] = byte

    head = 0x7FC0
    rom[head:head + 21] = title.ljust(21)[:21].encode("ascii")
    rom[head + 0x15] = 0x20             # LoROM, SlowROM
    rom[head + 0x16] = 0x00             # ROM only
    rom[head + 0x17] = 0x08
    rom[head + 0x18] = 0x00             # no SRAM
    rom[head + 0x19] = 0x01             # NTSC
    rom[head + 0x1A] = 0x33
    rom[head + 0x1B] = 0x00

    def put(off, value):
        rom[off] = value & 0xFF
        rom[off + 1] = (value >> 8) & 0xFF

    nmi = labels.get("nmi", labels["__nmi"]) & 0xFFFF
    irq = labels.get("irq", labels["__irq"]) & 0xFFFF
    for off in range(0x7FE0, 0x8000, 2):
        put(off, 0xFFFF)
    put(0x7FE4, irq)                    # native COP
    put(0x7FE6, irq)                    # native BRK
    put(0x7FEA, nmi)                    # native NMI
    put(0x7FEE, irq)                    # native IRQ
    put(0x7FF4, irq)                    # emulation COP
    put(0x7FFA, nmi)                    # emulation NMI
    put(0x7FFC, labels["__entry"] & 0xFFFF)
    put(0x7FFE, irq)                    # emulation IRQ

    checksum = sum(rom) & 0xFFFF
    put(head + 0x1E, checksum)
    put(head + 0x1C, checksum ^ 0xFFFF)
    return bytes(rom), labels


class Results:
    """Reads back what the test program wrote."""

    def __init__(self, machine, labels, finished, frames, instructions):
        self.machine = machine
        self.labels = labels
        self.finished = finished
        self.frames = frames
        self.instructions = instructions

    def __getitem__(self, index):
        return self.machine.bus.read(WRAM_BASE + RESULT_ADDR + index)

    def byte(self, index):
        return self[index]

    def word(self, index):
        return self[index] | (self[index + 1] << 8)

    def bytes(self, index, count):
        return [self[index + i] for i in range(count)]

    def read(self, addr):
        return self.machine.bus.read(addr)


def run(source, max_frames=60, title="PYSNES TEST"):
    """Assemble, boot and run until the program signals completion."""
    from snes.system import System

    image, labels = assemble_image(source, title)
    machine = System(rom_data=image)

    executed = 0
    finished = False
    for _ in range(max_frames):
        machine.run_frame()
        executed = machine.cpu.instructions
        if machine.bus.read(WRAM_BASE + DONE_ADDR):
            finished = True
            break
    return Results(machine, labels, finished, machine.frame_count, executed)
