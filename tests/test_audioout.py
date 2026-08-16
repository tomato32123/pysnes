"""Audio output, with a dummy device.

`snes/audioout.py` is sixty-eight lines and nothing named it.  Two of the
things it does break audibly and can be checked without a sound card.

`pygame.mixer.Sound(buffer=...)` reads raw bytes in the mixer's own format
and does not resample, so a mixer opened at 44100 replays the S-DSP's 32 kHz
samples 1.378 times too fast.  The class re-opens the device to fix that, and
if the check were dropped the emulator would still make sound -- fast,
high-pitched sound, which is the kind of wrong that gets blamed on the timing
core.

And the backlog is bounded.  If emulation runs ahead of playback -- fast
forward, a slow machine -- the queue has to stop growing rather than turn
into latency and then into memory.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (name, got, want))


class FakeDSP(object):
    """Hands out as many samples as asked for, forever."""

    def __init__(self):
        self.given = 0

    def take_samples(self, n):
        self.given += n
        return bytes(n)


class FakeAPU(object):
    def __init__(self):
        self.dsp = FakeDSP()


class FakeMachine(object):
    def __init__(self):
        self.apu = FakeAPU()


def main():
    import pygame
    from snes.audioout import AudioOut, SAMPLE_RATE

    pygame.init()

    # A mixer already open at the wrong rate has to be re-opened, not used.
    pygame.mixer.quit()
    pygame.mixer.init(frequency=44100, size=-16, channels=2, buffer=1024)
    check("the wrong rate is what we set up", pygame.mixer.get_init()[0], 44100)
    machine = FakeMachine()
    out = AudioOut(machine)
    check("the device was re-opened at the DSP's rate",
          pygame.mixer.get_init()[0], SAMPLE_RATE)

    # Emulation running far ahead of playback must not grow without bound.
    for _ in range(400):
        out.feed(machine)
    check("the backlog is bounded", len(out.buffer) <= out.max_backlog, True)
    if machine.apu.dsp.given == 0:
        FAILURES.append("nothing was ever taken from the DSP")

    out.close()

    print()
    if FAILURES:
        print("%d failure(s):" % len(FAILURES))
        for line in FAILURES:
            print("  " + line)
        return 1
    print("all audio-output tests passed (%d bytes taken, backlog %d of %d)"
          % (machine.apu.dsp.given, len(out.buffer), out.max_backlog))
    return 0


if __name__ == "__main__":
    sys.exit(main())
