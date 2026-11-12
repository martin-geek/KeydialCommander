"""Test the macOS service path without capturing or posting real input."""
import asyncio
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock

import pytest
from aiohttp import ClientSession

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS backend")


async def test_macos_driver_serves_editor_with_privacy_permissions_missing(
    monkeypatch, tmp_path, config
):
    from huion_keydial_mini import _macos
    from huion_keydial_mini.device import HuionKeydialMini

    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    # Use a short, isolated socket path even under a long pytest temp path.
    socket_dir = TemporaryDirectory(prefix="keydial-test-", dir="/tmp")
    monkeypatch.setattr("huion_keydial_mini.ipc.runtime_dir", lambda: Path(socket_dir.name))
    monkeypatch.setattr(_macos, "can_post", lambda: False)
    start_capture = Mock()
    monkeypatch.setattr(_macos, "start_capture", start_capture)
    config.data["api"]["port"] = 0
    driver = HuionKeydialMini(config)
    try:
        await driver.start()
        async with ClientSession(f"http://127.0.0.1:{driver.api_server.bound_port}") as session:
            async with session.get("/") as response:
                assert response.status == 200
            async with session.get("/api/status") as response:
                status = await response.json()
            assert status["device"]["state"] == "output_unavailable"
            assert status["output"]["available"] is False
            async with session.get("/api/keys") as response:
                keys = (await response.json())["all"]
            assert "KEY_LEFTMETA" in keys
            assert "KEY_F24" not in keys
        start_capture.assert_not_called()
    finally:
        await driver.stop()
        socket_dir.cleanup()


async def test_capture_rearms_after_held_controls_and_disconnect(monkeypatch):
    from huion_keydial_mini import _macos
    from huion_keydial_mini.input_events import EventType, InputEvent
    from huion_keydial_mini.input_translator import InputTranslator
    from huion_keydial_mini.macos import MacInputSource

    events, resets, connections = [], [], []

    async def on_event(event):
        events.append(event)

    source = MacInputSource(on_event, InputTranslator(), connections.append, lambda: True)
    source.on_reset = resets.append
    batches = iter([
        (1, True, 1, []),
        (1, False, 0, [(1, 0)]),
        (1, False, 0, [(1, 1), (1, 0), (20, -1), (20, 1), (19, 1), (19, 0)]),
        (0, True, 0, []),
    ])
    stop_capture = Mock()
    monkeypatch.setattr(_macos, "can_listen", lambda: True)
    monkeypatch.setattr(_macos, "start_capture", lambda: True)
    monkeypatch.setattr(_macos, "poll_capture", lambda: next(batches, (0, False, 0, [])))
    monkeypatch.setattr(_macos, "stop_capture", stop_capture)

    disconnected = asyncio.Event()
    def on_readiness():
        if connections == [True, False]:
            disconnected.set()

    source.on_readiness = on_readiness
    await source.start()
    try:
        await asyncio.wait_for(disconnected.wait(), timeout=2)
        assert events == [
            InputEvent(kind, control)
            for control in ("BUTTON_1", "DIAL_CW", "DIAL_CCW", "DIAL_CLICK")
            for kind in (EventType.KEY_PRESS, EventType.KEY_RELEASE)
        ]
        assert resets == ["input_changed", "input_changed"]
        assert source.state == "disconnected"
    finally:
        await source.stop()
    stop_capture.assert_called_once_with()


async def test_command_a_and_shared_modifier_ownership(monkeypatch, config):
    from huion_keydial_mini import _macos
    from huion_keydial_mini.action_engine import ActionRejected
    from huion_keydial_mini.macos import MacKeyOutput

    post_key = Mock()
    monkeypatch.setattr(_macos, "can_post", lambda: True)
    monkeypatch.setattr(_macos, "post_key", post_key)
    output = MacKeyOutput(config)
    await output.start()
    output.acquire("held-command", ["KEY_LEFTMETA"])
    await output.emit_keys(["KEY_LEFTMETA", "KEY_A"])
    with pytest.raises(ActionRejected, match="unsupported_key"):
        await output.emit_keys(["KEY_LEFTMETA", "KEY_F24"])
    output.close()

    assert [call.args for call in post_key.call_args_list] == [
        (0x37, True, True, 0x100008),
        (0x00, True, False, 0x100008),
        (0x00, False, False, 0x100008),
        (0x37, False, True, 0),
    ]
