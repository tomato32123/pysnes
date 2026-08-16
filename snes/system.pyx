# cython: language_level=3
"""Top-level machine: owns the components and runs the emulation loop."""

import os

from libc.stdint cimport uint8_t, uint16_t, uint32_t, int64_t

from snes.cart cimport Cart
from snes.ppu cimport PPU
from snes.apu cimport APU
from snes.bus cimport Bus
from snes.cpu cimport CPU

from snes.cart import Cart as PyCart
from snes.ppu import PPU as PyPPU
from snes.apu import APU as PyAPU
from snes.bus import Bus as PyBus
from snes.cpu import CPU as PyCPU


# When frozen by PyInstaller the package lives in a temporary extraction
# directory that is deleted on exit, so saves must sit next to the executable.
def _app_dir():
    """Where battery saves live.

    $PYSNES_HOME overrides it, which is how a test can exercise the save
    naming and the import of older ones without writing into a real
    collection -- there was no test for any of that until there was a way to
    run one somewhere harmless.
    """
    import sys
    said = os.environ.get("PYSNES_HOME")
    if said:
        return said
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))


# Controller bit layout as seen at $4218/$4219 and through $4016.
BUTTONS = {
    "B": 0x8000, "Y": 0x4000, "SELECT": 0x2000, "START": 0x1000,
    "UP": 0x0800, "DOWN": 0x0400, "LEFT": 0x0200, "RIGHT": 0x0100,
    "A": 0x0080, "X": 0x0040, "L": 0x0020, "R": 0x0010,
}


cdef class System:
    cdef readonly Cart cart
    cdef readonly PPU ppu
    cdef readonly APU apu
    cdef readonly Bus bus
    cdef readonly CPU cpu
    cdef readonly object rom_path
    cdef readonly object sram_path

    def __init__(self, rom_path=None, bytes rom_data=None, bint use_saves=True):
        """`use_saves=False` starts from an empty battery and never writes one.

        A run meant to be compared against another run must depend on the
        cartridge and nothing else.  With saves on it also depends on what is
        in pysnes/saves/ and on any .srm sitting beside the ROM, so the same
        image in two folders can reach two different screens -- which is
        exactly what happened when a library baseline was first taken, and
        looked like the emulator had stopped being deterministic.
        """
        self.rom_path = rom_path
        self.cart = PyCart(rom_path, rom_data)
        self.ppu = PyPPU()
        self.apu = PyAPU()
        self.bus = PyBus(self.cart, self.ppu, self.apu)
        self.cpu = PyCPU(self.bus)
        self.sram_path = None
        if use_saves and rom_path and self.cart.sram_size:
            # Battery saves live in pysnes/saves/, never next to the ROM: an
            # existing .srm there belongs to whatever emulator wrote it and
            # must not be overwritten.  It is still read once, to import it.
            saves = os.path.join(_app_dir(), "saves")
            os.makedirs(saves, exist_ok=True)
            name = os.path.splitext(os.path.basename(rom_path))[0]
            # The cartridge's own checksum is in the name.  Keyed by file
            # name alone, two different games that happen to share one --
            # which is not rare in a collection sorted into folders -- write
            # over each other's battery, and the second one to be opened
            # loses a save with nothing said.
            self.sram_path = os.path.join(
                saves, "%s-%04X.srm" % (name, self.cart.computed_checksum))
            # Older saves, in order: the name without a checksum, which is
            # what this wrote before, and then one sitting beside the ROM,
            # which belongs to whatever emulator put it there.  Both are read
            # once and then written back to the new name.
            if not self.cart.load_sram(self.sram_path):
                if not self.cart.load_sram(os.path.join(saves, name + ".srm")):
                    self.cart.load_sram(os.path.splitext(rom_path)[0] + ".srm")

    def reset(self):
        self.ppu.reset()
        self.apu.reset()
        self.bus.reset()
        self.cpu.do_reset()

    # -- execution ---------------------------------------------------------

    def step(self, int count=1):
        cdef int i
        for i in range(count):
            self.cpu.step()

    def run_frame(self, int64_t max_instructions=20_000_000):
        """Run until the PPU reaches the start of VBlank."""
        cdef int64_t executed = 0
        self.bus.frame_ready = 0
        while not self.bus.frame_ready:
            self.cpu.step()
            executed += 1
            if executed >= max_instructions:
                break
        self.bus.frame_ready = 0
        return executed

    def run_frames(self, int n):
        cdef int i
        cdef int64_t total = 0
        for i in range(n):
            total += self.run_frame()
        return total

    # -- input --------------------------------------------------------------

    def set_pad(self, int index, int mask):
        self.bus.set_pad(index, mask)

    def press(self, names, int index=0):
        cdef int mask = 0
        for name in names:
            mask |= BUTTONS[name.upper()]
        self.bus.set_pad(index, mask)

    @property
    def state_path(self):
        """Where F2/F4 keep their snapshot: alongside the battery save."""
        if not self.rom_path:
            return None
        name = os.path.splitext(os.path.basename(self.rom_path))[0]
        saves = os.path.join(_app_dir(), "saves")
        os.makedirs(saves, exist_ok=True)
        return os.path.join(saves, name + ".state")

    # -- persistence ---------------------------------------------------------

    def save_sram(self):
        if self.sram_path:
            return self.cart.save_sram(self.sram_path)
        return False

    # -- save states ---------------------------------------------------------

    def _state_dict(self):
        return {
            "version": 3,
            "title": self.cart.title,
            "checksum": self.cart.computed_checksum,
            "rom_size": self.cart.rom_size,
            "cpu": (self.cpu.state_ints(), self.cpu.state_blobs()),
            "bus": (self.bus.state_ints(), self.bus.state_blobs()),
            "ppu": (self.ppu.state_ints(), self.ppu.state_blobs()),
            "apu": (self.apu.state_ints(), self.apu.state_blobs()),
            "dsp": (self.apu.dsp.state_ints(), self.apu.dsp.state_blobs()),
            "sram": bytes(self.cart.sram_data),
            # The cartridge, if it has anything on it.  A state that leaves the
            # board out restores the console around a coprocessor still doing
            # whatever it had reached -- which is what rewind did in every SA-1
            # and SuperFX game until this was added.  The board's name goes in
            # so a state cannot be loaded into a different cartridge's chip.
            "board": self._board_state(),
        }

    def _board_state(self):
        board = self.bus.board
        if not hasattr(board, "state_ints"):
            return None
        out = {"name": board.name,
               "ints": board.state_ints(),
               "blobs": board.state_blobs()}
        if hasattr(board, "extra_state"):
            out["extra"] = board.extra_state()
        return out

    def _apply_state(self, data):
        if data.get("version") != 3:
            raise ValueError("unsupported save-state version")
        if (data.get("checksum") != self.cart.computed_checksum
                or data.get("rom_size") != self.cart.rom_size):
            raise ValueError("save state belongs to a different ROM (%s)"
                             % data.get("title"))
        for name, obj in (("cpu", self.cpu), ("bus", self.bus), ("ppu", self.ppu),
                          ("apu", self.apu), ("dsp", self.apu.dsp)):
            ints, blobs = data[name]
            obj.load_ints(ints)
            obj.load_blobs(blobs)
        sram = data["sram"]
        n = min(len(sram), len(self.cart.sram_data))
        self.cart.sram_data[:n] = sram[:n]

        saved = data.get("board")
        board = self.bus.board
        if saved is not None:
            if saved["name"] != board.name:
                raise ValueError("save state is from a %s cartridge, this one is %s"
                                 % (saved["name"], board.name))
            board.load_ints(saved["ints"])
            board.load_blobs(saved["blobs"])
            if "extra" in saved:
                board.load_extra(saved["extra"])
        elif hasattr(board, "state_ints"):
            raise ValueError("save state has no cartridge state, but this "
                             "cartridge has a %s on it" % board.name)
        return True

    def save_state_raw(self):
        """Uncompressed snapshot.  Rewind uses this and picks its own codec,
        since compression dominates the cost of taking one."""
        import pickle
        return pickle.dumps(self._state_dict(), 4)

    def load_state_raw(self, blob):
        import pickle
        return self._apply_state(pickle.loads(blob))

    def save_state(self):
        """Serialise the whole machine to a compressed blob."""
        import zlib
        return zlib.compress(self.save_state_raw(), 6)

    def load_state(self, blob):
        import zlib
        return self.load_state_raw(zlib.decompress(blob))

    # -- introspection --------------------------------------------------------

    @property
    def framebuffer(self):
        return self.ppu.framebuffer_obj

    @property
    def visible_width(self):
        """The framebuffer is always 512 across.  A normal picture is 256
        pixels written twice; hires and mode 5/6 fill all 512."""
        return 512

    @property
    def visible_height(self):
        """Rows the PPU actually drew: 224, or 239 with overscan, and twice
        that under interlace.  The buffer is the largest of those, so the
        rest is left black."""
        cdef int lines = self.bus.vblank_start - 1
        return lines * 2 if self.ppu.screen_interlace else lines

    @property
    def frame_count(self):
        return self.bus.frame

    @property
    def master_clock(self):
        return self.bus.master_clock

    def state(self):
        r = self.cpu.regs
        return ("PC=%02X:%04X A=%04X X=%04X Y=%04X S=%04X D=%04X DB=%02X "
                "P=%02X(%s) E=%d  V=%d H=%d frame=%d"
                % (r["pb"], r["pc"], r["a"], r["x"], r["y"], r["s"], r["d"],
                   r["db"], r["p"], self.cpu.flags, r["e"],
                   self.bus.vcounter, self.bus.hcounter, self.bus.frame))
