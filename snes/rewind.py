"""Rewind: a ring of recent save states the player can step back through.

Snapshot cost drove the design.  Measured on Dragon Quest VI, one state is
267 KB raw and takes 0.38 ms to build; zlib level 1 brings it to 87 KB for
3.4 ms, and higher levels buy almost nothing (84 KB at level 6) for 40% more
time.  Capturing every third frame at level 1 therefore averages about 1.1 ms
per frame against a 7.4 ms budget, and twenty seconds of history costs roughly
35 MB.

Because snapshots are three emulated frames apart, holding rewind and loading
one per displayed frame plays back at 3x reverse speed, which is the usual
feel for the feature.
"""

import zlib
from collections import deque


class Rewind:
    def __init__(self, seconds=20.0, interval=3, level=1, enabled=True):
        self.interval = max(1, int(interval))
        self.level = level
        self.enabled = enabled
        self.capacity = max(1, int(seconds * 60.0 / self.interval))
        self.frames = deque(maxlen=self.capacity)
        self._countdown = 0
        self._bytes = 0

    # -- recording ---------------------------------------------------------

    def capture(self, machine):
        """Call once per emulated frame; snapshots are taken every `interval`."""
        if not self.enabled:
            return False
        if self._countdown > 0:
            self._countdown -= 1
            return False
        self._countdown = self.interval - 1

        blob = zlib.compress(machine.save_state_raw(), self.level)
        if len(self.frames) == self.frames.maxlen and self.frames:
            self._bytes -= len(self.frames[0])
        self.frames.append(blob)
        self._bytes += len(blob)
        return True

    # -- playback -----------------------------------------------------------

    def step_back(self, machine):
        """Load the previous snapshot.  False once the history runs out."""
        if len(self.frames) < 2:
            return False
        self._bytes -= len(self.frames.pop())
        machine.load_state_raw(zlib.decompress(self.frames[-1]))
        # Do not re-capture the frame we just restored to.
        self._countdown = self.interval - 1
        return True

    def clear(self):
        self.frames.clear()
        self._bytes = 0
        self._countdown = 0

    # -- reporting ------------------------------------------------------------

    @property
    def seconds_held(self):
        return len(self.frames) * self.interval / 60.0

    @property
    def megabytes(self):
        return self._bytes / (1024.0 * 1024.0)

    def describe(self):
        if not self.enabled:
            return "rewind: off"
        return ("rewind: %.1fs held, %.1f MB (capacity %.0fs)"
                % (self.seconds_held, self.megabytes,
                   self.capacity * self.interval / 60.0))
