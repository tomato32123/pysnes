"""Run a libretro core and hand back the pictures it draws.

This project has had no second opinion about its own video output beyond
krom's thirty-five reference screenshots.  A libretro core built from
someone else's emulator gives one for every ROM here.

Read what that is and is not.  Another emulator is not hardware, and this
one is built for speed rather than exactness, so a difference between the
two says only that they disagree -- it does not say which is right.  What
it does say is *where* to look, which is the expensive part of finding a
defect.  Nothing in this file should ever be treated as a verdict.

The core is not in this repository and should not be.  Build one and
point at it:

    git clone --depth 1 https://github.com/snes9xgit/snes9x
    git clone --depth 1 https://github.com/libretro/libretro-common
    cd snes9x
    g++ -O2 -shared -fPIC -D__LIBRETRO__ -DRIGHTSHIFT_IS_SAR -DHAVE_STDINT_H \\
        -I. -Ilibretro -I../libretro-common/include -o snes9x_libretro.so \\
        $(ls *.cpp | grep -vE '^(cpuops|spc7110dec|spc7110emu|srtcemu)\\.cpp$') \\
        apu/*.cpp filter/*.cpp libretro/libretro.cpp

    PYSNES_REFCORE=/path/to/snes9x_libretro.so python tools/refcore.py <rom>

Building it by hand, without the core's own build system, was tried here and
got to one remaining error before being stopped.  What that established, so
the next attempt need not:

  * `make` is not on this machine, in the system or in the conda
    environment, and installing it would be the short way to all of this.
  * Four sources are #included by others rather than compiled --
    spc7110dec, spc7110emu, srtcemu, and inside apu/bapu the algorithms,
    core, core/oppseudo_*, disassembler, iplrom, memory and timing files.
    cpuops.cpp is the exception: it is both included *and* compiled, and
    leaving it out costs the main opcode tables.
  * The audio sources live under apu/bapu, two levels down, and the NTSC
    filter is C rather than C++, so a *.cpp glob misses both.
  * Include paths needed: the tree root, apu, apu/bapu, libretro, and
    libretro-common/include from a separate clone.
  * SPC_DSP.h uses Resampler without including the header that declares it,
    relying on the including translation unit to have pulled it in first.

The bridge below is finished and unused, which is the same state
difftrace.py has been in since it was written: waiting for something to
compare against.
"""
import ctypes
import os
import sys

import numpy as np

# The handful of environment calls a core needs answered before it will run.
ENV_GET_SYSTEM_DIRECTORY = 9
ENV_SET_PIXEL_FORMAT = 10
ENV_GET_VARIABLE = 15
ENV_GET_SAVE_DIRECTORY = 31
ENV_SET_VARIABLES = 16
ENV_GET_LOG_INTERFACE = 27

PIXEL_RGB565 = 2


class GameInfo(ctypes.Structure):
    _fields_ = [("path", ctypes.c_char_p), ("data", ctypes.c_void_p),
                ("size", ctypes.c_size_t), ("meta", ctypes.c_char_p)]


class Core:
    """One libretro core, loaded and ready to be stepped a frame at a time."""

    def __init__(self, path):
        self.lib = ctypes.CDLL(path)
        self.frame = None
        self.pixel_format = PIXEL_RGB565
        self._keep = []

        env_t = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint, ctypes.c_void_p)
        vid_t = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_uint,
                                 ctypes.c_uint, ctypes.c_size_t)
        aud_t = ctypes.CFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t)
        aud1_t = ctypes.CFUNCTYPE(None, ctypes.c_int16, ctypes.c_int16)
        poll_t = ctypes.CFUNCTYPE(None)
        state_t = ctypes.CFUNCTYPE(ctypes.c_int16, ctypes.c_uint, ctypes.c_uint,
                                   ctypes.c_uint, ctypes.c_uint)

        def environment(cmd, data):
            if cmd == ENV_SET_PIXEL_FORMAT:
                self.pixel_format = ctypes.cast(
                    data, ctypes.POINTER(ctypes.c_int)).contents.value
                return True
            if cmd in (ENV_GET_SYSTEM_DIRECTORY, ENV_GET_SAVE_DIRECTORY):
                p = ctypes.cast(data, ctypes.POINTER(ctypes.c_char_p))
                p.contents = ctypes.c_char_p(self._dir)
                return True
            return False

        def video(data, width, height, pitch):
            if not data:
                return
            buf = ctypes.string_at(data, pitch * height)
            self.frame = (buf, width, height, pitch)

        self._dir = os.fsencode(os.path.dirname(os.path.abspath(path)))
        self.cb = [env_t(environment), vid_t(video),
                   aud_t(lambda d, f: f), aud1_t(lambda l, r: None),
                   poll_t(lambda: None), state_t(lambda p, d, i, k: 0)]

        self.lib.retro_set_environment(self.cb[0])
        self.lib.retro_set_video_refresh(self.cb[1])
        self.lib.retro_set_audio_sample_batch(self.cb[2])
        self.lib.retro_set_audio_sample(self.cb[3])
        self.lib.retro_set_input_poll(self.cb[4])
        self.lib.retro_set_input_state(self.cb[5])
        self.lib.retro_init()

    def load(self, rom):
        with open(rom, "rb") as fh:
            data = fh.read()
        buf = ctypes.create_string_buffer(data)
        self._keep.append(buf)
        info = GameInfo(os.fsencode(rom), ctypes.cast(buf, ctypes.c_void_p),
                        len(data), None)
        if not self.lib.retro_load_game(ctypes.byref(info)):
            raise RuntimeError("the core would not load %s" % rom)

    def run(self, frames):
        for _ in range(frames):
            self.lib.retro_run()

    def picture(self):
        """The last frame as (height, width, 3) in 8 bits a channel."""
        if self.frame is None:
            return None
        buf, width, height, pitch = self.frame
        if self.pixel_format == PIXEL_RGB565:
            words = np.frombuffer(buf, dtype="<u2").reshape(height, pitch // 2)
            words = words[:, :width].astype(np.uint32)
            r = ((words >> 11) & 0x1F) << 3
            g = ((words >> 5) & 0x3F) << 2
            b = (words & 0x1F) << 3
        else:                                    # XRGB8888
            words = np.frombuffer(buf, dtype="<u4").reshape(height, pitch // 4)
            words = words[:, :width]
            r = (words >> 16) & 0xFF
            g = (words >> 8) & 0xFF
            b = words & 0xFF
        return np.dstack([r, g, b]).astype(np.uint8)


def main():
    core_path = os.environ.get("PYSNES_REFCORE", "")
    if not core_path or not os.path.exists(core_path):
        print("no reference core: set PYSNES_REFCORE to a built libretro .so")
        return 1
    if len(sys.argv) < 2:
        print("usage: refcore.py <rom> [frames]")
        return 1
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 300

    core = Core(core_path)
    core.load(sys.argv[1])
    core.run(frames)
    picture = core.picture()
    if picture is None:
        print("the core drew nothing in %d frames" % frames)
        return 1
    print("the reference drew %dx%d after %d frames, %d distinct colours"
          % (picture.shape[1], picture.shape[0], frames,
             len(np.unique(picture.reshape(-1, 3), axis=0))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
