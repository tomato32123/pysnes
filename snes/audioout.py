"""Streaming audio output for the pygame frontend.

The S-DSP produces 32 kHz stereo samples into a ring buffer.  Each video frame
we drain that ring and keep a small queue of pygame Sound chunks playing back
to back, trimming the backlog if emulation runs ahead so latency stays bounded.
"""

import pygame

SAMPLE_RATE = 32000
CHANNELS = 2
BYTES_PER_FRAME = CHANNELS * 2          # signed 16-bit stereo


class AudioOut:
    def __init__(self, machine, chunk_frames=1024, max_backlog_chunks=4):
        self.machine = machine
        self.chunk_bytes = chunk_frames * BYTES_PER_FRAME
        self.max_backlog = self.chunk_bytes * max_backlog_chunks

        if not pygame.mixer.get_init():
            pygame.mixer.init(frequency=SAMPLE_RATE, size=-16,
                              channels=CHANNELS, buffer=512)
        got = pygame.mixer.get_init()
        if got is None:
            raise RuntimeError("could not open an audio device")
        if got[0] != SAMPLE_RATE:
            # The mixer resamples for us, but warn since pitch accuracy suffers.
            print("audio: device runs at %d Hz, DSP output is %d Hz" % (got[0], SAMPLE_RATE))

        pygame.mixer.set_num_channels(max(8, pygame.mixer.get_num_channels()))
        self.channel = pygame.mixer.Channel(0)
        self.buffer = bytearray()
        self._keep_alive = []

    def feed(self, machine=None):
        dsp = (machine or self.machine).apu.dsp
        self.buffer += dsp.take_samples(8192)

        while len(self.buffer) >= self.chunk_bytes:
            if self.channel.get_busy() and self.channel.get_queue() is not None:
                break                                # both slots are full
            chunk = bytes(self.buffer[:self.chunk_bytes])
            del self.buffer[:self.chunk_bytes]
            sound = pygame.mixer.Sound(buffer=chunk)
            # Sound objects must outlive playback; keep the last few around.
            self._keep_alive.append(sound)
            del self._keep_alive[:-4]
            if self.channel.get_busy():
                self.channel.queue(sound)
            else:
                self.channel.play(sound)

        if len(self.buffer) > self.max_backlog:
            del self.buffer[:len(self.buffer) - self.chunk_bytes]

    def close(self):
        try:
            self.channel.stop()
        finally:
            pygame.mixer.quit()
