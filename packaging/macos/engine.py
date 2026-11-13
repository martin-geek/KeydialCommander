"""Private service bundled with the macOS desktop application."""
import asyncio
import json
import logging
import os
import signal
import sys

from huion_keydial_mini.config import Config
from huion_keydial_mini.device import HuionKeydialMini


async def run(token):
    loop = asyncio.get_running_loop()
    done = asyncio.Event()
    stdin = sys.stdin.fileno()
    loop.add_reader(stdin, done.set)
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, done.set)
    if os.environ.pop("KEYDIAL_USB_TABLET_MODE", "") == "1":
        from huion_keydial_mini import _macos
        _macos.enable_usb_tablet()
    driver = HuionKeydialMini(Config.load(), native_token=token)
    try:
        await driver.start()
        print(json.dumps({"port": driver.api_server.bound_port}), flush=True)
        await done.wait()
    finally:
        loop.remove_reader(stdin)
        await driver.stop()


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    asyncio.run(run(os.environ.pop("KEYDIAL_NATIVE_TOKEN")))
