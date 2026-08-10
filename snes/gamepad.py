"""Gamepad input.

Pads are read through SDL's GameController layer, so a controller reports
"the bottom face button" rather than "button 3" and one mapping works across
Xbox, DualShock, Switch Pro and the rest. Anything SDL does not recognise
falls back to raw joystick indices.

The default layout matches physical positions rather than labels: the SNES
face buttons are rotated a quarter turn from an Xbox pad, so SNES B (bottom)
sits on Xbox A (bottom), SNES A (right) on Xbox B (right), and so on.
"""

import json
import os

import pygame

# SNES controller bits, as seen at $4218/$4219.
BUTTONS = {
    "B": 0x8000, "Y": 0x4000, "SELECT": 0x2000, "START": 0x1000,
    "UP": 0x0800, "DOWN": 0x0400, "LEFT": 0x0200, "RIGHT": 0x0100,
    "A": 0x0080, "X": 0x0040, "L": 0x0020, "R": 0x0010,
}

# SNES button -> SDL GameController button name.
DEFAULT_MAPPING = {
    "B": "a",
    "A": "b",
    "Y": "x",
    "X": "y",
    "L": "leftshoulder",
    "R": "rightshoulder",
    "START": "start",
    "SELECT": "back",
    "UP": "dpup",
    "DOWN": "dpdown",
    "LEFT": "dpleft",
    "RIGHT": "dpright",
}

# Emulator functions, not SNES buttons.  Empty string = unbound.
DEFAULT_FUNCTIONS = {
    "FASTFORWARD": "righttrigger",
    "SAVESTATE": "",
    "LOADSTATE": "",
}

# Raw-joystick fallback: button indices in the order most pads enumerate them.
FALLBACK_MAPPING = {
    "B": 0, "A": 1, "Y": 2, "X": 3,
    "L": 4, "R": 5, "SELECT": 6, "START": 7,
}

_SDL_BUTTONS = {
    "a": pygame.CONTROLLER_BUTTON_A,
    "b": pygame.CONTROLLER_BUTTON_B,
    "x": pygame.CONTROLLER_BUTTON_X,
    "y": pygame.CONTROLLER_BUTTON_Y,
    "back": pygame.CONTROLLER_BUTTON_BACK,
    "guide": pygame.CONTROLLER_BUTTON_GUIDE,
    "start": pygame.CONTROLLER_BUTTON_START,
    "leftstick": pygame.CONTROLLER_BUTTON_LEFTSTICK,
    "rightstick": pygame.CONTROLLER_BUTTON_RIGHTSTICK,
    "leftshoulder": pygame.CONTROLLER_BUTTON_LEFTSHOULDER,
    "rightshoulder": pygame.CONTROLLER_BUTTON_RIGHTSHOULDER,
    "dpup": pygame.CONTROLLER_BUTTON_DPAD_UP,
    "dpdown": pygame.CONTROLLER_BUTTON_DPAD_DOWN,
    "dpleft": pygame.CONTROLLER_BUTTON_DPAD_LEFT,
    "dpright": pygame.CONTROLLER_BUTTON_DPAD_RIGHT,
}

_SDL_TRIGGERS = {
    "lefttrigger": pygame.CONTROLLER_AXIS_TRIGGERLEFT,
    "righttrigger": pygame.CONTROLLER_AXIS_TRIGGERRIGHT,
}

STICK_DEADZONE = 0.5           # fraction of full deflection that counts as a press
TRIGGER_THRESHOLD = 0.3


class Pad:
    """One physical controller bound to one SNES port."""

    def __init__(self, device_index, mapping, functions):
        self.device_index = device_index
        self.mapping = dict(mapping)
        self.functions = dict(functions)
        self.controller = None
        self.joystick = None
        self.name = "unknown"

        from pygame._sdl2 import controller as sdl_controller
        if sdl_controller.is_controller(device_index):
            self.controller = sdl_controller.Controller(device_index)
            self.name = self.controller.name
            self.instance_id = self.controller.as_joystick().get_instance_id()
        else:
            self.joystick = pygame.joystick.Joystick(device_index)
            self.joystick.init()
            self.name = self.joystick.get_name()
            self.instance_id = self.joystick.get_instance_id()

    # -- reading ----------------------------------------------------------

    def _pressed(self, binding):
        if not binding:
            return False
        if self.controller is not None:
            if binding in _SDL_BUTTONS:
                return bool(self.controller.get_button(_SDL_BUTTONS[binding]))
            if binding in _SDL_TRIGGERS:
                value = self.controller.get_axis(_SDL_TRIGGERS[binding]) / 32767.0
                return value > TRIGGER_THRESHOLD
            return False
        # Raw joystick: bindings are plain button indices.
        try:
            index = int(binding)
        except (TypeError, ValueError):
            return False
        if index < self.joystick.get_numbuttons():
            return bool(self.joystick.get_button(index))
        return False

    def _stick_direction(self):
        """Left stick, reported as d-pad presses once past the deadzone."""
        if self.controller is not None:
            x = self.controller.get_axis(pygame.CONTROLLER_AXIS_LEFTX) / 32767.0
            y = self.controller.get_axis(pygame.CONTROLLER_AXIS_LEFTY) / 32767.0
        elif self.joystick.get_numaxes() >= 2:
            x = self.joystick.get_axis(0)
            y = self.joystick.get_axis(1)
        else:
            return 0

        mask = 0
        if x <= -STICK_DEADZONE:
            mask |= BUTTONS["LEFT"]
        elif x >= STICK_DEADZONE:
            mask |= BUTTONS["RIGHT"]
        if y <= -STICK_DEADZONE:
            mask |= BUTTONS["UP"]
        elif y >= STICK_DEADZONE:
            mask |= BUTTONS["DOWN"]
        return mask

    def _hat_direction(self):
        """Raw joysticks report the d-pad as a hat rather than as buttons."""
        if self.joystick is None or self.joystick.get_numhats() == 0:
            return 0
        x, y = self.joystick.get_hat(0)
        mask = 0
        if x < 0:
            mask |= BUTTONS["LEFT"]
        elif x > 0:
            mask |= BUTTONS["RIGHT"]
        if y > 0:
            mask |= BUTTONS["UP"]
        elif y < 0:
            mask |= BUTTONS["DOWN"]
        return mask

    def mask(self):
        mask = 0
        for name, binding in self.mapping.items():
            if name in BUTTONS and self._pressed(binding):
                mask |= BUTTONS[name]
        mask |= self._stick_direction()
        mask |= self._hat_direction()
        # Opposite directions at once confuse games; drop both.
        if (mask & BUTTONS["LEFT"]) and (mask & BUTTONS["RIGHT"]):
            mask &= ~(BUTTONS["LEFT"] | BUTTONS["RIGHT"])
        if (mask & BUTTONS["UP"]) and (mask & BUTTONS["DOWN"]):
            mask &= ~(BUTTONS["UP"] | BUTTONS["DOWN"])
        return mask

    def function(self, name):
        return self._pressed(self.functions.get(name, ""))

    def close(self):
        try:
            if self.controller is not None:
                self.controller.quit()
            elif self.joystick is not None:
                self.joystick.quit()
        except Exception:
            pass


class Pads:
    """All connected controllers, assigned to SNES ports in plug order."""

    MAX_PLAYERS = 2

    def __init__(self, config_path=None):
        pygame.joystick.init()
        from pygame._sdl2 import controller as sdl_controller
        sdl_controller.init()
        self._sdl_controller = sdl_controller

        self.config_path = config_path
        self.config = self._load_config()
        self.pads = []
        self._edges = {}
        self.rescan()

    # -- configuration -----------------------------------------------------

    def _load_config(self):
        config = {"_default": {"buttons": dict(DEFAULT_MAPPING),
                               "functions": dict(DEFAULT_FUNCTIONS)}}
        if not self.config_path:
            return config
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, encoding="utf-8") as fh:
                    stored = json.load(fh)
                if isinstance(stored, dict):
                    config.update(stored)
            except (OSError, ValueError) as exc:
                print("gamepad config ignored (%s): %s" % (self.config_path, exc))
        else:
            self._write_config(config)
        return config

    def _write_config(self, config):
        try:
            os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
            with open(self.config_path, "w", encoding="utf-8") as fh:
                json.dump(config, fh, indent=2, sort_keys=True)
                fh.write("\n")
        except OSError:
            pass

    def _mapping_for(self, name):
        entry = self.config.get(name) or self.config["_default"]
        buttons = dict(DEFAULT_MAPPING)
        buttons.update(entry.get("buttons", {}))
        functions = dict(DEFAULT_FUNCTIONS)
        functions.update(entry.get("functions", {}))
        return buttons, functions

    # -- device management --------------------------------------------------

    def signature(self):
        return tuple((p.name, p.device_index) for p in self.pads)

    def rescan(self):
        for pad in self.pads:
            pad.close()
        self.pads = []
        count = pygame.joystick.get_count()
        for index in range(min(count, self.MAX_PLAYERS)):
            try:
                probe = (self._sdl_controller.Controller(index).name
                         if self._sdl_controller.is_controller(index)
                         else pygame.joystick.Joystick(index).get_name())
            except pygame.error:
                continue
            buttons, functions = self._mapping_for(probe)
            if not self._sdl_controller.is_controller(index):
                # Unrecognised pad: bindings are raw button indices.
                buttons = {k: FALLBACK_MAPPING.get(k, "") for k in DEFAULT_MAPPING}
            try:
                self.pads.append(Pad(index, buttons, functions))
            except pygame.error as exc:
                print("could not open controller %d: %s" % (index, exc))
        return self.pads

    def handle_event(self, event):
        """Re-scan on hotplug.  True only when the set of pads really changed --
        SDL posts an ADDED event for devices that were already plugged in."""
        if event.type not in (pygame.CONTROLLERDEVICEADDED, pygame.CONTROLLERDEVICEREMOVED,
                              pygame.JOYDEVICEADDED, pygame.JOYDEVICEREMOVED):
            return False
        before = self.signature()
        self.rescan()
        return self.signature() != before

    # -- reading -------------------------------------------------------------

    def mask(self, player):
        if player < len(self.pads):
            return self.pads[player].mask()
        return 0

    def any_function(self, name):
        return any(pad.function(name) for pad in self.pads)

    def pressed_once(self, name):
        """True only on the frame a function binding goes from released to held."""
        now = self.any_function(name)
        was = self._edges.get(name, False)
        self._edges[name] = now
        return now and not was

    def describe(self):
        if not self.pads:
            return "no gamepad detected"
        return "\n".join(
            "  port %d: %s (%s)" % (i + 1, pad.name,
                                    "GameController" if pad.controller else "raw joystick")
            for i, pad in enumerate(self.pads))

    def close(self):
        for pad in self.pads:
            pad.close()
        self.pads = []
