"""Show live gamepad state so a mapping can be checked without booting a game."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame
from snes.gamepad import Pads, BUTTONS

ORDER = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "L", "R", "START", "SELECT"]

pygame.init()
pygame.display.set_mode((320, 120))
pygame.display.set_caption("pysnes - gamepad test (Esc to quit)")
pads = Pads(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "config", "gamepad.json"))
print(pads.describe())
print("press buttons; Esc or close the window to quit")
print()

clock = pygame.time.Clock()
running = True
last = None
while running:
    for e in pygame.event.get():
        if e.type == pygame.QUIT or (e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE):
            running = False
        if pads.handle_event(e):
            print(pads.describe())
    line = []
    for player in range(2):
        m = pads.mask(player)
        if m or player == 0:
            held = [n for n in ORDER if m & BUTTONS[n]]
            line.append("P%d[%s]" % (player + 1, " ".join(held) if held else "-"))
    if pads.any_function("FASTFORWARD"):
        line.append("FF")
    text = "  ".join(line)
    if text != last:
        print("\r%-70s" % text, end="", flush=True)
        last = text
    clock.tick(60)
print()
pads.close()
pygame.quit()
