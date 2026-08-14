"""The emulator, with a phone around it.

The machine itself needs nothing from this file -- the cores have no idea
whether they are on a desktop or a phone, and that was checked rather than
assumed.  What is here is only the three things a phone has that a desktop
does not: a screen of an awkward shape, no keyboard, and a speaker that
wants to be fed in small mouthfuls.

Laid out for landscape, because a 4:3 picture on a portrait screen wastes
two thirds of the glass.  The controls sit *over* the picture at the sides
rather than below it, for the same reason: a phone held sideways has room
at the left and right of a 4:3 frame and none above or below.

    buildozer -v android debug
"""
import os
import sys

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")

import pygame

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from snes.system import System, BUTTONS

# Where a phone lets an app keep files it can see.  The first ROM found is
# the one that runs; picking between several is a screen this does not have
# yet, and pretending otherwise would be worse than the honest limitation.
ROM_DIRS = [
    "/sdcard/pysnes",
    "/storage/emulated/0/pysnes",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "roms"),
]
ROM_SUFFIXES = (".smc", ".sfc", ".swc", ".fig")

PICTURE_W, PICTURE_H = 512, 478          # what the PPU hands over
VISIBLE_W = 256                          # dots across, before doubling

# The pad is laid out inside whatever the picture leaves free, not across the
# whole screen.  A 4:3 frame fitted to the height of a long phone leaves a
# band down each side; putting a thumb there costs nothing, while putting it
# over the picture costs the picture.  Positions are worked out per screen in
# Screen.layout(), from the band's own width -- a wider phone gets bigger
# buttons rather than buttons further from the glass edge.
#
# Each entry is (name, x, y, r) with x and y as fractions of the band and of
# the screen height, so the arrangement holds its shape on any phone.
LEFT_BAND = [
    ("UP",     0.50, 0.470, 0.055),
    ("DOWN",   0.50, 0.760, 0.055),
    ("LEFT",   0.22, 0.615, 0.055),
    ("RIGHT",  0.78, 0.615, 0.055),
    ("L",      0.35, 0.150, 0.058),
    ("SELECT", 0.50, 0.930, 0.042),
]
RIGHT_BAND = [
    ("Y",      0.22, 0.615, 0.053),
    ("X",      0.50, 0.470, 0.053),
    ("B",      0.50, 0.760, 0.053),
    ("A",      0.78, 0.615, 0.053),
    ("R",      0.65, 0.150, 0.058),
    ("START",  0.50, 0.930, 0.042),
]

FACE = {"A": (208, 92, 92), "B": (214, 190, 96), "X": (96, 132, 208),
        "Y": (104, 176, 120)}


def find_rom():
    for directory in ROM_DIRS:
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if name.lower().endswith(ROM_SUFFIXES):
                return os.path.join(directory, name)
    return None


class Touch:
    """Which buttons the fingers on the glass are holding down.

    A phone reports fingers, not buttons, so the mapping has to be redone
    every frame from wherever the fingers currently are -- a finger that
    slides from one button to the next presses the second without ever
    being lifted, which is how a physical pad behaves too.
    """

    def __init__(self, width, height, layout):
        self.size = (width, height)
        self.layout = layout
        self.fingers = {}

    def resize(self, width, height):
        self.size = (width, height)

    def handle(self, event):
        if event.type == pygame.FINGERDOWN or event.type == pygame.FINGERMOTION:
            self.fingers[event.finger_id] = (event.x, event.y)
        elif event.type == pygame.FINGERUP:
            self.fingers.pop(event.finger_id, None)
        # A mouse is a finger, for running this on a desktop while writing it.
        elif event.type == pygame.MOUSEBUTTONDOWN:
            self.fingers["mouse"] = (event.pos[0] / self.size[0],
                                     event.pos[1] / self.size[1])
        elif event.type == pygame.MOUSEMOTION and "mouse" in self.fingers:
            self.fingers["mouse"] = (event.pos[0] / self.size[0],
                                     event.pos[1] / self.size[1])
        elif event.type == pygame.MOUSEBUTTONUP:
            self.fingers.pop("mouse", None)

    def held(self):
        """The buttons under the fingers, in pixels rather than fractions.

        The layout is worked out once per screen and handed here, so a
        finger's position is compared against where the buttons actually
        are rather than against a second copy of the arithmetic.
        """
        width, height = self.size
        bits = 0
        for fx, fy in self.fingers.values():
            x, y = fx * width, fy * height
            for name, cx, cy, r in self.layout:
                dx, dy = x - cx, y - cy
                if dx * dx + dy * dy <= r * r:
                    bits |= BUTTONS[name]
        return bits


class Screen:
    """The picture, stretched to the glass by the GPU rather than the CPU.

    Two million pixels a frame is more work than emulating the console, so
    the frame is uploaded at the size the PPU drew it and the hardware does
    the stretching -- the same reason the desktop front end works this way.
    """

    def __init__(self, size=None):
        """`size` forces a screen shape, so a phone's layout can be drawn and
        looked at on a machine that is not a phone."""
        pygame.display.init()
        if size is None:
            info = pygame.display.Info()
            size = (info.current_w, info.current_h)
            self.window = pygame.display.set_mode(size, pygame.FULLSCREEN)
        else:
            self.window = pygame.display.set_mode(size)
        self.width, self.height = self.window.get_size()
        self.frame = pygame.Surface((VISIBLE_W, 224))
        self.buffer = pygame.Surface((PICTURE_W, PICTURE_H))
        self.layout = self.pad_layout()

    def show(self, framebuffer, visible_height):
        # The PPU writes two columns a dot so hires modes have somewhere to
        # put their left half; the right column of each pair is the picture.
        raw = pygame.image.frombuffer(bytes(framebuffer), (PICTURE_W, PICTURE_H),
                                      "BGRA")
        picture = pygame.transform.scale(
            raw.subsurface((0, 0, PICTURE_W, max(1, visible_height))),
            self.fit(visible_height))
        self.window.fill((0, 0, 0))
        rect = picture.get_rect(center=(self.width // 2, self.height // 2))
        self.window.blit(picture, rect)

    def fit(self, visible_height):
        """The largest 4:3 rectangle that fits, in whole pixels."""
        wanted = 4.0 / 3.0
        if self.width / float(self.height) > wanted:
            height = self.height
            width = int(height * wanted)
        else:
            width = self.width
            height = int(width / wanted)
        return (width, height)

    def pad_layout(self):
        """Where each button sits, in pixels, given this screen.

        The bands are what the picture does not cover.  If a screen is so
        square that there is nothing spare -- a tablet at 4:3 -- the buttons
        fall back to a strip over the lowest part of the picture, which is
        the least bad place for them.
        """
        picture_w, _ = self.fit(224)
        band = max(0, (self.width - picture_w) // 2)
        overlay = band < self.height * 0.16
        if overlay:
            band = int(self.height * 0.16)
        out = []
        for entries, origin in ((LEFT_BAND, 0), (RIGHT_BAND, self.width - band)):
            for name, fx, fy, r in entries:
                out.append((name,
                            origin + fx * band,
                            fy * self.height,
                            max(14.0, r * self.height)))
        return out

    def draw_pad(self, held):
        for name, cx, cy, r in self.layout:
            down = bool(held & BUTTONS[name])
            colour = FACE.get(name, (150, 150, 158))
            pygame.draw.circle(self.window, colour, (int(cx), int(cy)),
                               int(r), 0 if down else 3)

    def flip(self):
        pygame.display.flip()


def main():
    rom = find_rom()
    pygame.init()
    screen = Screen()
    font = pygame.font.Font(None, max(18, screen.height // 22))

    if rom is None:
        # Say what is missing and where to put it, rather than a blank screen.
        screen.window.fill((16, 17, 22))
        lines = ["No cartridge found.",
                 "Put a .smc or .sfc file in:",
                 ROM_DIRS[0]]
        for i, text in enumerate(lines):
            image = font.render(text, True, (232, 231, 227))
            screen.window.blit(image, (screen.width // 12,
                                       screen.height // 3 + i * font.get_height() * 3 // 2))
        screen.flip()
        while True:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    return 0
            pygame.time.wait(200)

    machine = System(rom)
    touch = Touch(screen.width, screen.height, screen.layout)

    audio = None
    try:
        from snes.audioout import AudioOut
        audio = AudioOut(machine)
    except Exception:
        audio = None                     # sound is not worth failing over

    clock = pygame.time.Clock()
    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.APP_WILLENTERBACKGROUND:
                machine.save_sram()
            else:
                touch.handle(event)

        machine.set_pad(0, touch.held())
        machine.run_frame()
        screen.show(machine.framebuffer, machine.visible_height)
        screen.draw_pad(touch.held())
        screen.flip()
        if audio is not None:
            audio.feed(machine)
        clock.tick(60)

    machine.save_sram()
    pygame.quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
