"""Select the output key table for the host, using shared profile key names."""
import sys

from .linux_keymap import LINUX_KEY_NAMES, linux_key_mapping

if sys.platform == "darwin":
    from .macos_keymap import KEY_MAPPING
else:
    KEY_MAPPING = linux_key_mapping()

SUPPORTED_KEYS = sorted(KEY_MAPPING)
PROFILE_KEYS = frozenset(LINUX_KEY_NAMES) | KEY_MAPPING.keys()
