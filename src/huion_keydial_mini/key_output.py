"""Output key ownership shared by the Linux and macOS endpoints."""
import logging
from typing import List

from .input_events import InputEvent, EventType
from .keymap import KEY_MAPPING

logger = logging.getLogger(__name__)


class OutputUnavailable(RuntimeError):
    """The output endpoint is unavailable or its state is uncertain."""


class KeyOutput:
    """Track which actions own each injected key."""

    KEY_MAPPING = KEY_MAPPING

    def __init__(self, config, keybind_manager=None):
        self.config = config
        self.keybind_manager = keybind_manager
        self.device = None
        self._activations = {}
        self._owners = {}
        self._possibly_down = set()
        self.failed = False
        self.cleanup_confirmed = True
        self.on_fault = None

    @property
    def available(self):
        return self.device is not None and not self.failed

    def _resolve_keys(self, keys):
        return tuple(dict.fromkeys(self.KEY_MAPPING[name] for name in keys
                                   if name in self.KEY_MAPPING))

    def close(self) -> None:
        """Release owned output before retiring the endpoint; safe to repeat."""
        try:
            self.release_all()
        except OutputUnavailable:
            pass
        self._close_endpoint()

    def _close_endpoint(self):
        device, self.device = self.device, None
        if device is not None:
            try:
                device.close()
            except Exception:
                self.cleanup_confirmed = False
                logger.exception("Error closing key output endpoint")

    def _fault(self, error):
        if self.failed:
            return
        self.failed = True
        self.cleanup_confirmed = True
        # Include uncertain writes: a write or SYN can fail after taking effect.
        for code in list(self._possibly_down):
            try:
                self._write_key(code, False)
                self._possibly_down.discard(code)
            except Exception:
                self.cleanup_confirmed = False
        self._activations.clear()
        self._owners.clear()
        self._possibly_down.clear()
        self._close_endpoint()
        if self.on_fault:
            self.on_fault(error)

    def acquire(self, owner, keys):
        """Acquire concrete keys for an activation without disturbing other owners."""
        if self.failed or self.device is None:
            raise OutputUnavailable("Output unavailable")
        if owner in self._activations:
            return
        codes = self._resolve_keys(keys)
        self._activations[owner] = codes
        try:
            for code in codes:
                owners = self._owners.setdefault(code, set())
                if not owners:
                    self._possibly_down.add(code)
                    self._write_key(code, True)
                owners.add(owner)
        except Exception as error:
            self._fault(error)
            raise OutputUnavailable("Output unavailable") from error

    def release(self, owner):
        """Release the activation's original keys, independent of current bindings."""
        codes = self._activations.pop(owner, ())
        try:
            for code in reversed(codes):
                owners = self._owners[code]
                owners.discard(owner)
                if not owners:
                    self._write_key(code, False)
                    self._possibly_down.discard(code)
                    del self._owners[code]
        except Exception as error:
            self._fault(error)
            raise OutputUnavailable("Output unavailable") from error

    def release_all(self):
        for owner in list(self._activations):
            self.release(owner)

    async def send_event(self, event: InputEvent):
        owner = ("binding", event.key_code)
        # Release must precede the mutable binding lookup, even after deletion.
        if event.event_type == EventType.KEY_RELEASE:
            self.release(owner)
            return
        action = (self.keybind_manager.get_action(event.key_code)
                  if self.keybind_manager else None)
        if action and action.type in ("keystroke", "keyboard"):
            self.acquire(owner, action.keys or [])

    async def emit_keys(self, keys: List[str]):
        """A tap owns its keys for this atomic, non-suspending output operation."""
        owner = object()
        self.acquire(owner, keys)
        self.release(owner)

    def get_supported_keys(self) -> List[str]:
        """Get list of supported key names."""
        return list(self.KEY_MAPPING.keys())
