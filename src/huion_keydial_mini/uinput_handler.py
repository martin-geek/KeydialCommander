"""UInput handler for generating Linux input events."""

import asyncio
import logging
from typing import Optional, Dict
import evdev
from evdev import UInput, ecodes

from .config import Config
from .key_output import KeyOutput, OutputUnavailable
from .input_events import InputEvent, EventType
from .keybind_manager import KeybindManager


logger = logging.getLogger(__name__)


class UInputHandler(KeyOutput):
    """Generate keyboard events through Linux uinput."""

    def __init__(self, config: Config, keybind_manager: Optional[KeybindManager] = None):
        super().__init__(config, keybind_manager)
        self.capabilities = self._build_capabilities()

    def _write_key(self, code, pressed):
        self.device.write(ecodes.EV_KEY, code, int(pressed))
        self.device.syn()

    async def start(self, retries: int = 10, delay: float = 0.5) -> None:
        """Create the virtual device without blocking the event loop (audit H6)."""
        loop = asyncio.get_event_loop()
        last_error = None
        for attempt in range(retries):
            try:
                self.device = await loop.run_in_executor(
                    None, lambda: UInput(events=self.capabilities,
                                         name=self.config.uinput_device_name))
                logger.info(f"Opened uinput device '{self.config.uinput_device_name}'")
                return
            except Exception as e:
                last_error = e
                logger.info(f"uinput not ready (attempt {attempt + 1}/{retries}): {e}")
                await asyncio.sleep(delay)
        raise RuntimeError(f"Could not open uinput device after {retries} attempts: {last_error}")

    def _build_capabilities(self) -> Dict:
        """Build device capabilities based on configuration and keybind manager."""
        capabilities = {
            evdev.ecodes.EV_KEY: [],
            # Add mouse relative events for scroll and movement
            evdev.ecodes.EV_REL: [evdev.ecodes.REL_X, evdev.ecodes.REL_Y, evdev.ecodes.REL_WHEEL, evdev.ecodes.REL_HWHEEL],
        }

        # Add all possible keys that might be used
        for key_name in self.KEY_MAPPING.keys():
            key_code = self.KEY_MAPPING.get(key_name)
            if key_code and key_code not in capabilities[evdev.ecodes.EV_KEY]:
                capabilities[evdev.ecodes.EV_KEY].append(key_code)

        # Add keys from keybind manager if available
        if self.keybind_manager:
            for action in self.keybind_manager.get_all_actions().values():
                if action.keys:
                    for key_name in action.keys:
                        key_code = self.KEY_MAPPING.get(key_name)
                        if key_code and key_code not in capabilities[evdev.ecodes.EV_KEY]:
                            capabilities[evdev.ecodes.EV_KEY].append(key_code)

        return capabilities

    def set_keybind_manager(self, keybind_manager: KeybindManager):
        """Set the keybind manager and rebuild capabilities."""
        self.keybind_manager = keybind_manager
        self.capabilities = self._build_capabilities()
        logger.info("Updated keybind manager and rebuilt capabilities")
