"""Rewind: a ring of recent save states the player can step back through.

Snapshot cost drove the design.  Measured on Dragon Quest VI, building a raw
state takes 0.38 ms; compressing it with zlib level 1 takes another 3.4 ms and
cuts 511 KB down to about 118 KB, and higher levels buy almost nothing for
noticeably more time.

Doing both on the game loop put a 4.5 ms spike on every third frame, which
pushed the 99th-percentile frame to the edge of the 16.7 ms budget.  So only
the raw snapshot is taken on the main thread; compression is handed to a
worker.  zlib releases the GIL while it works, so that time genuinely
overlaps with emulation rather than merely being deferred.

Snapshots sit three emulated frames apart, so holding rewind and restoring one
per displayed frame plays back at 3x reverse speed.
"""

import threading
import zlib
from collections import deque

RAW, PACKED = 0, 1


class Rewind:
    MAX_PENDING = 3

    def __init__(self, seconds=20.0, interval=3, level=1, enabled=True, threaded=True):
        self.interval = max(1, int(interval))
        self.level = level
        self.enabled = enabled
        self.capacity = max(1, int(seconds * 60.0 / self.interval))
        self.frames = deque(maxlen=self.capacity)
        self._countdown = 0
        self._lock = threading.Lock()
        self._pending = deque()
        self._wake = threading.Semaphore(0)
        self._stop = False
        self._worker = None
        if enabled and threaded:
            self._worker = threading.Thread(target=self._compress_loop,
                                            name="rewind-compress", daemon=True)
            self._worker.start()

    # -- recording ---------------------------------------------------------

    def capture(self, machine):
        """Call once per emulated frame; snapshots are taken every `interval`."""
        if not self.enabled:
            return False
        if self._countdown > 0:
            self._countdown -= 1
            return False
        self._countdown = self.interval - 1

        # A two-slot list so the worker can swap the payload in place without
        # disturbing the ring's ordering.
        entry = [RAW, machine.save_state_raw()]
        with self._lock:
            self.frames.append(entry)
        # Backpressure: an uncompressed snapshot is ~4x the size of a packed
        # one, so if the worker falls behind (fast-forward, a slow machine)
        # compress inline rather than let raw states pile up.
        if self._worker is not None and len(self._pending) < self.MAX_PENDING:
            self._pending.append(entry)
            self._wake.release()
        else:
            entry[0], entry[1] = PACKED, zlib.compress(entry[1], self.level)
        return True

    def _compress_loop(self):
        while True:
            self._wake.acquire()
            if self._stop:
                return
            try:
                entry = self._pending.popleft()
            except IndexError:
                continue
            if entry[0] == RAW:
                packed = zlib.compress(entry[1], self.level)
                # The ring may have evicted this entry meanwhile; harmless.
                if entry[0] == RAW:
                    entry[0], entry[1] = PACKED, packed

    # -- playback -----------------------------------------------------------

    def step_back(self, machine):
        """Load the previous snapshot.  False once the history runs out."""
        with self._lock:
            if len(self.frames) < 2:
                return False
            self.frames.pop()
            entry = self.frames[-1]
            kind, payload = entry[0], entry[1]
        machine.load_state_raw(zlib.decompress(payload) if kind == PACKED else payload)
        # Do not immediately re-record the frame we just restored to.
        self._countdown = self.interval - 1
        return True

    def clear(self):
        with self._lock:
            self.frames.clear()
        self._pending.clear()
        self._countdown = 0

    def close(self):
        if self._worker is not None:
            self._stop = True
            self._wake.release()
            self._worker.join(timeout=1.0)
            self._worker = None

    # -- reporting ------------------------------------------------------------

    @property
    def seconds_held(self):
        return len(self.frames) * self.interval / 60.0

    @property
    def megabytes(self):
        with self._lock:
            total = sum(len(e[1]) for e in self.frames)
        return total / (1024.0 * 1024.0)

    def describe(self):
        if not self.enabled:
            return "rewind: off"
        return ("rewind: %.1fs held, %.1f MB (capacity %.0fs)"
                % (self.seconds_held, self.megabytes,
                   self.capacity * self.interval / 60.0))
