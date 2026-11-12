"""macOS K20 capture and Quartz output for the shared action engine."""
import asyncio
import logging

from . import _macos
from .action_engine import ActionRejected
from .key_output import KeyOutput
from .macos_keymap import KEY_MAPPING

logger = logging.getLogger(__name__)

# Quartz's combined modifier flags plus the left/right device flags.
MODIFIERS = {
    0x37: (0x100000, 0x08), 0x36: (0x100000, 0x10),  # Command
    0x38: (0x020000, 0x02), 0x3C: (0x020000, 0x04),  # Shift
    0x3B: (0x040000, 0x01), 0x3E: (0x040000, 0x2000),  # Control
    0x3A: (0x080000, 0x20), 0x3D: (0x080000, 0x40),  # Option
}


class MacKeyOutput(KeyOutput):
    KEY_MAPPING = KEY_MAPPING

    async def start(self):
        self.device = self
        if not self.available:
            logger.warning("Allow Accessibility for your terminal to enable shortcut output")

    @property
    def available(self):
        return self.device is not None and not self.failed and _macos.can_post()

    def _resolve_keys(self, keys):
        if any(key not in self.KEY_MAPPING for key in keys):
            raise ActionRejected("unsupported_key")
        return super()._resolve_keys(keys)

    def _close_endpoint(self):
        self.device = None

    def _write_key(self, code, pressed):
        if not _macos.can_post():
            raise PermissionError("macOS Accessibility permission is required")
        active = self._possibly_down
        flags = 0
        for key in active:
            if key in MODIFIERS and (key != code or pressed):
                common, side = MODIFIERS[key]
                flags |= common | side
        _macos.post_key(code, pressed, code in MODIFIERS, flags)


class MacInputSource:
    """Track one exclusively seized K20 session and rearm after invalidation."""

    STATES = ("disconnected", "ready", "capture_failed", "missing_input")

    def __init__(self, on_event, translator, on_state, output_available):
        self.on_event = on_event
        self.translator = translator
        self.on_state = on_state
        self.output_available = output_available
        self.on_reset = self.on_readiness = None
        self.recovery_complete = lambda: True
        self._connected = self._capturing = False
        self._task = None
        self._held = 0
        self._epoch = 0
        self._rearming = True
        self._suspended = None
        self._capture_state = self.state = "disconnected"
        self.ready = False

    @property
    def preview_allowed(self):
        return self.ready or self.state in ("disconnected", "input_permission_required")

    async def start(self):
        self._suspended = None
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        self.suspend("stopped")
        task, self._task = self._task, None
        if task:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    def _stop_capture(self):
        if self._capturing:
            _macos.stop_capture()
            self._capturing = False
        self._held = 0

    def suspend(self, reason):
        self._suspended = reason
        self._stop_capture()
        self._capture_state = "disconnected"
        self.resynchronize(reason)

    def resynchronize(self, reason="input_changed"):
        self._epoch += 1
        self.ready = False
        self._rearming = True
        self.translator.reset()
        if self.on_reset:
            self.on_reset(reason)
        self._update_state()

    def _update_state(self):
        connected = self._capture_state in ("ready", "missing_input")
        state = self._suspended or self._capture_state
        if state == "ready":
            if not self.recovery_complete():
                state = "recovering"
            elif self._rearming and self._held:
                state = "release_controls"
        changed = state != self.state or connected != self._connected
        self.state, self.ready = state, state == "ready"
        if self.ready:
            self._rearming = False
        if connected != self._connected:
            self._connected = connected
            self.on_state(connected)
        if changed and self.on_readiness:
            self.on_readiness()

    async def _run(self):
        slow_ticks = 0
        try:
            while not self._suspended:
                if slow_ticks == 0 or not self._capturing:
                    if not self.output_available():
                        self._wait_for("output_unavailable")
                    elif not _macos.can_listen():
                        self._wait_for("input_permission_required")
                    elif not self._capturing:
                        self._capturing = _macos.start_capture()
                        if not self._capturing:
                            self._wait_for("capture_failed")
                if self._capturing:
                    state, reset, held, events = _macos.poll_capture()
                    self._capture_state = self.STATES[state]
                    if reset:
                        self._held = held
                        self.resynchronize()
                    else:
                        self._update_state()
                        await self._dispatch_batch(events, held)
                    slow_ticks = (slow_ticks + 1) % 100
                    await asyncio.sleep(0.01)
                else:
                    await asyncio.sleep(1)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("macOS K20 capture stopped unexpectedly")
            self.suspend("capture_failed")
        finally:
            self._stop_capture()

    def _wait_for(self, state):
        if self._capture_state != state or self._capturing:
            self._stop_capture()
            self._capture_state = state
            if state == "input_permission_required":
                logger.warning("Allow Input Monitoring for your terminal to enable K20 capture")
            elif state == "capture_failed":
                logger.warning("Could not open macOS HID capture")
            self.resynchronize(state)

    async def _dispatch_batch(self, events, held):
        epoch = self._epoch
        for control, value in events:
            if epoch != self._epoch:
                break
            if control != 20:
                bit = 1 << (control - 1)
                if value:
                    self._held |= bit
                else:
                    self._held &= ~bit
            if self.ready:
                for event in self._translate(control, value):
                    if epoch != self._epoch:
                        break
                    await self.on_event(event)
            else:
                self._update_state()

        if epoch != self._epoch and self._capturing:
            # No part of a pre-change batch may trigger bindings in the new
            # profile. Still account for all the physical controls it reports.
            self._held = held
            self._rearming = True
            self._update_state()

    def _translate(self, control, value):
        if control == 20:
            if not value:
                return []
            return self.translator.feed_dial("DIAL_CW" if value < 0 else "DIAL_CCW")
        if control == 19:
            return self.translator.feed_dial_click(bool(value))
        return self.translator.feed_button(f"BUTTON_{control}", bool(value))
