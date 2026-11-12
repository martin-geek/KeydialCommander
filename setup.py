"""Build the native HID and Quartz bridge when installing on macOS."""
import sys

from setuptools import Extension, setup

extensions = []
if sys.platform == "darwin":
    extensions.append(Extension(
        "huion_keydial_mini._macos",
        ["src/huion_keydial_mini/_macos.m"],
        extra_link_args=[
            "-framework", "IOKit", "-framework", "CoreFoundation",
            "-framework", "CoreGraphics", "-framework", "AppKit",
        ],
    ))

setup(ext_modules=extensions)
