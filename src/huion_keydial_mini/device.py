"""Connect the platform input and output backends to the Commander engine."""
import logging
import sys

from .config import Config
from .key_output import OutputUnavailable
from .keybind_manager import KeybindManager
from .event_bus import EventBus
from .profile_store import ProfileStore
from .input_translator import InputTranslator
from .input_events import InputEvent, EventType
from .action_engine import ActionEngine
from . import __version__


logger = logging.getLogger(__name__)


class HuionKeydialMini:
    """Translate K20 input and execute actions through the host backend."""

    def __init__(self, config: Config, *, native_token=None):
        self.config = config
        self.native_mode = native_token is not None
        self.debug_mode = getattr(config, 'debug_mode', False)
        self.running = False
        self._stopping = False

        # Control plane (unchanged from Phase 1)
        self.event_bus = EventBus()
        self.profile_store = ProfileStore()
        self.profile_store.ensure_initialized(legacy_config=config)
        self.keybind_manager = KeybindManager(config, profile_store=self.profile_store,
                                              event_bus=self.event_bus)
        self.translator = InputTranslator(self.keybind_manager)
        if sys.platform == 'darwin':
            from .macos import MacInputSource, MacKeyOutput
            self.uinput_handler = MacKeyOutput(config, self.keybind_manager)
            self.evdev_source = MacInputSource(
                on_event=self._dispatch,
                translator=self.translator,
                on_state=self._on_state,
                output_available=lambda: self.uinput_handler.available,
            )
            self.evdev_source.on_observed_press = lambda action: self.event_bus.publish({
                "type": "key_event", "action_id": action, "pressed": True,
            })
        else:
            from .evdev_source import EvdevSource
            from .uinput_handler import UInputHandler
            self.uinput_handler = UInputHandler(config, self.keybind_manager)
            self.evdev_source = EvdevSource(
                on_event=self._dispatch,
                translator=self.translator,
                on_state=self._on_state,
                exclude_names={self.uinput_handler.config.uinput_device_name},
            )
        self.action_engine = ActionEngine(self.keybind_manager, self.uinput_handler)
        if self.native_mode:
            self.action_engine.show_settings_preview = (
                lambda: self.event_bus.publish({'type': 'settings_preview'}))

        # Commander API (embedded aiohttp server)
        from .api_server import ApiServer
        self.api_server = ApiServer(
            keybind_manager=self.keybind_manager,
            profile_store=self.profile_store,
            event_bus=self.event_bus,
            action_engine=self.action_engine,
            version=__version__,
            port=0 if self.native_mode else config.api_port,
            native_token=native_token,
        )

        self.evdev_source.on_reset = self._reset_actions
        self.evdev_source.on_readiness = self._publish_readiness
        self.keybind_manager.on_bindings_changing = (
            lambda: self.evdev_source.resynchronize('profile_changed'))
        self.uinput_handler.on_fault = self._output_failed
        self.action_engine.admission = self._admit_action
        self.evdev_source.recovery_complete = lambda: self.action_engine.settled
        self.action_engine.on_tasks_changed = self.evdev_source._update_state
        self.api_server.runtime_status = self._runtime_status

    def _admit_action(self, preview):
        if self._stopping or not self.uinput_handler.available:
            return False
        return (self.evdev_source.preview_allowed if preview else self.evdev_source.ready)

    def _reset_actions(self, reason):
        try:
            self.action_engine.invalidate(reason)
        except OutputUnavailable:
            # The writer already retired the endpoint and reported the fault.
            pass

    def _output_failed(self, error):
        self.evdev_source.suspend('output_unavailable')

    def _runtime_status(self):
        return {
            'device': {'ready': self.evdev_source.ready, 'state': self.evdev_source.state,
                       **getattr(self.evdev_source, 'device_info', {})},
            'output': {'available': self.uinput_handler.available,
                       'cleanup_confirmed': self.uinput_handler.cleanup_confirmed},
            'actions': {'busy_count': self.action_engine.busy_count},
        }

    def _publish_readiness(self):
        self.event_bus.publish({'type': 'device_state', 'connected': self.evdev_source._connected,
                                'battery': None, **self._runtime_status()['device']})

    async def start(self):
        """Start the driver: socket server, platform backends, and web API."""
        logger.info("Starting Huion Keydial Mini driver...")
        try:
            if not self.native_mode:
                await self.keybind_manager.start_socket_server()
            await self.uinput_handler.start()
            await self.evdev_source.start()
            await self.api_server.start()
            self.running = True
            logger.info("Commander service started")
        except Exception as e:
            logger.error(f"Failed to start driver: {e}")
            await self.stop()
            raise

    async def stop(self):
        """Revoke output before potentially slow HTTP or socket teardown."""
        self.running = False
        self._stopping = True
        await self.evdev_source.stop()
        await self.action_engine.drain()
        self.uinput_handler.close()
        try:
            await self.api_server.stop()
        finally:
            if not self.native_mode:
                await self.keybind_manager.stop_socket_server()

    async def _dispatch(self, event: InputEvent):
        """Execute a translated action and announce it on the bus."""
        try:
            generation = self.action_engine.generation
            await self.action_engine.execute(event, generation=generation)
            if generation != self.action_engine.generation:
                return
            self.event_bus.publish({
                "type": "key_event",
                "action_id": event.key_code,
                "pressed": event.event_type == EventType.KEY_PRESS,
            })
            if self.debug_mode:
                logger.debug(f"Dispatched: {event.event_type} - {event.key_code}")
        except Exception as e:
            logger.error(f"Error dispatching event: {e}")

    def _on_state(self, connected: bool):
        """Publish device connect/disconnect (battery filled in separately)."""
        logger.info("Device %s", "connected" if connected else "disconnected")
        self.api_server.set_device_connected(connected)
        self.event_bus.publish({"type": "device_state",
                                "connected": connected, "battery": None})
