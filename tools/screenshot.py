"""Run N frames and write the framebuffer out as a PNG (no PIL needed)."""
import os, struct, sys, zlib
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tools.romarg import from_argv
from snes.system import System

W, H = 256, 239
ROM = from_argv()
def write_png(path, fb):
    """fb is 0xAARRGGBB little-endian -> bytes B,G,R,A."""
    raw = bytearray()
    for y in range(H):
        raw.append(0)                       # filter type: none
        base = y * W * 4
        for x in range(W):
            i = base + x * 4
            raw += bytes((fb[i + 2], fb[i + 1], fb[i + 0]))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        fh.write(chunk(b"IEND", b""))


def main():
    frames = [int(a) for a in sys.argv[1:]] or [300]
    outdir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shots")
    os.makedirs(outdir, exist_ok=True)
    s = System(ROM)
    for target in sorted(frames):
        while s.frame_count < target:
            s.run_frame()
        # The frame that just ended is complete; render one more to be safe.
        s.run_frame()
        path = os.path.join(outdir, "frame%04d.png" % target)
        write_png(path, s.framebuffer)
        nonblack = sum(1 for i in range(0, W * H * 4, 4)
                       if s.framebuffer[i] or s.framebuffer[i + 1] or s.framebuffer[i + 2])
        print("%s  non-black pixels: %d/%d" % (path, nonblack, W * H))
        print("   " + s.ppu.dump().replace(chr(10), chr(10) + "   "))


if __name__ == "__main__":
    main()
