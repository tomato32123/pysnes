"""Save state must reproduce the machine exactly: same state in -> same frames out."""
import hashlib, os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv, any_rom, NO_ROM
from snes.system import System, BUTTONS

# A cartridge, any cartridge, but the same one every run: these check
# that the machine can be put back exactly as it was, and that needs
# something real to put back rather than a particular thing.
ROM = from_argv(quiet=True) if len(sys.argv) > 1 else any_rom()
def digest(machine):
    return hashlib.sha1(bytes(machine.framebuffer)).hexdigest()


def main():
    if ROM is None:
        sys.stderr.write("no cartridge to check a state against; set "
                         "PYSNES_ROMS or pass one" + chr(10))
        return NO_ROM
    s = System(ROM)
    for _ in range(1750):
        s.run_frame()

    blob = s.save_state()
    print("state size: %d bytes (%.1f KB)" % (len(blob), len(blob) / 1024))

    # Run forward and remember what the next 120 frames look like.
    marks = []
    for i in range(120):
        s.run_frame()
        if i % 30 == 29:
            marks.append(digest(s))
    after = (digest(s), s.cpu.regs, s.apu.regs["clock"], s.bus.frame)

    # Rewind and replay: every checkpoint must match.
    s.load_state(blob)
    replay = []
    for i in range(120):
        s.run_frame()
        if i % 30 == 29:
            replay.append(digest(s))
    after2 = (digest(s), s.cpu.regs, s.apu.regs["clock"], s.bus.frame)

    assert replay == marks, "frame checkpoints diverged:\n  %s\n  %s" % (marks, replay)
    assert after[0] == after2[0], "final framebuffer differs"
    assert after[1] == after2[1], "CPU registers differ:\n  %s\n  %s" % (after[1], after2[1])
    assert after[2] == after2[2], "APU clock differs: %d vs %d" % (after[2], after2[2])
    print("replayed 120 frames identically from the restored state")

    # A state from another ROM must be rejected.
    # Same header, different content: the guard must use the real ROM contents.
    tampered = bytearray(s.cart.rom_data)
    tampered[len(tampered) // 2] ^= 0xFF
    other = System(rom_data=bytes(tampered))
    try:
        bad = other.save_state()
    except Exception:
        bad = None
    if bad:
        try:
            s.load_state(bad)
        except ValueError as exc:
            print("mismatched ROM rejected: %s" % exc)
        else:
            raise AssertionError("a state from a different ROM was accepted")

    # A state written before the framebuffer was trimmed to the rows anything
    # reads carries the whole 512x478 buffer.  Someone's saved game is in that
    # shape, so it has to keep loading; the blob is copied by its own length
    # for exactly this reason and nothing but a test will keep it that way.
    import pickle
    fresh = s.save_state_raw()
    d = pickle.loads(fresh)
    blobs = list(d["ppu"][1])
    trimmed = len(blobs[3])
    blobs[3] = blobs[3] + bytes(978944 - trimmed)
    d["ppu"] = (d["ppu"][0], blobs)
    old_shape = pickle.dumps(d, 4)

    a, b = System(ROM), System(ROM)
    a.load_state_raw(old_shape)
    b.load_state_raw(fresh)
    for _ in range(30):
        a.run_frame()
        b.run_frame()
    rows = 512 * 224 * 4
    if bytes(a.framebuffer[:rows]) != bytes(b.framebuffer[:rows]):
        raise AssertionError("a state in the older framebuffer shape did not "
                             "restore to the same machine")
    print("older framebuffer shape still loads (%d bytes against %d)"
          % (978944, trimmed))

    print("all save-state tests passed")


if __name__ == "__main__":
    main()
