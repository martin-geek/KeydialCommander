"""Main entry point for the Huion Keydial Mini driver."""

import asyncio
import logging
import signal
import sys
import webbrowser
from typing import Optional

import click

from .device import HuionKeydialMini
from .config import Config


logger = logging.getLogger(__name__)


class DriverManager:
    """Manages the driver lifecycle."""

    def __init__(self, config: Config, open_editor=False):
        self.config = config
        self.open_editor = open_editor
        self.device: Optional[HuionKeydialMini] = None

    async def start(self):
        """Start the driver."""
        logger.info("Starting Huion Keydial Mini driver...")

        loop = asyncio.get_running_loop()
        shutdown = asyncio.Event()
        signals = []

        try:
            # Initialize the device
            self.device = HuionKeydialMini(self.config)

            # Set up signal handlers
            for sig in (signal.SIGINT, signal.SIGTERM):
                loop.add_signal_handler(sig, shutdown.set)
                signals.append(sig)

            # Start the device
            await self.device.start()

            url = f"http://127.0.0.1:{self.device.api_server.bound_port}"
            logger.info("Keydial Commander editor: %s", url)
            if self.open_editor:
                loop.run_in_executor(None, webbrowser.open, url)

            # Wait until a shutdown signal arrives (no polling)
            await shutdown.wait()
            logger.info("Shutdown signal received")

        except Exception as e:
            logger.error(f"Failed to start driver: {e}")
            raise
        finally:
            try:
                await self.stop()
            finally:
                for sig in signals:
                    loop.remove_signal_handler(sig)

    async def stop(self):
        """Stop the driver."""
        logger.info("Stopping driver...")

        if self.device:
            await self.device.stop()
            self.device = None

        logger.info("Driver stopped")


@click.command()
@click.option('--config', '-c',
              type=click.Path(exists=True),
              help='Path to configuration file')
@click.option('--device-address', '-d',
              help='Bluetooth MAC address of the device')
@click.option('--log-level', '-l',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR']),
              default='INFO',
              help='Set the logging level')
@click.option('--open', 'open_editor', is_flag=True, help='Open the editor in your default browser')
def main(config: Optional[str], device_address: Optional[str], log_level: str, open_editor: bool):
    """Huion Keydial Mini driver main entry point."""

    # Set up logging
    logging.basicConfig(
        level=getattr(logging, log_level),
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    try:
        # Load configuration
        app_config = Config.load(config, device_address)

        # Start the driver
        manager = DriverManager(app_config, open_editor=open_editor)
        asyncio.run(manager.start())

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Driver failed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
