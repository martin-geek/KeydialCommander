"""Exercise the foreground command across startup and signal shutdown."""
import asyncio
import signal
from types import SimpleNamespace
from unittest.mock import Mock

from click.testing import CliRunner

from huion_keydial_mini import main


def test_open_command_waits_for_shutdown_on_its_running_loop(monkeypatch):
    handlers = {}
    removed = []
    lifecycle = []
    browser_open = Mock()

    def add_handler(loop, sig, callback):
        handlers[sig] = callback

    def remove_handler(loop, sig):
        removed.append(sig)

    class Device:
        def __init__(self, config):
            self.api_server = SimpleNamespace(bound_port=8137)

        async def start(self):
            lifecycle.append("started")
            asyncio.get_running_loop().call_soon(handlers[signal.SIGINT])

        async def stop(self):
            lifecycle.append("stopped")

    monkeypatch.setattr(asyncio.SelectorEventLoop, "add_signal_handler", add_handler)
    monkeypatch.setattr(asyncio.SelectorEventLoop, "remove_signal_handler", remove_handler)
    monkeypatch.setattr(main, "HuionKeydialMini", Device)
    monkeypatch.setattr(main.webbrowser, "open", browser_open)

    result = CliRunner().invoke(main.main, ["--open"])

    assert result.exit_code == 0, result.output
    assert lifecycle == ["started", "stopped"]
    assert removed == [signal.SIGINT, signal.SIGTERM]
    browser_open.assert_called_once_with("http://127.0.0.1:8137")
