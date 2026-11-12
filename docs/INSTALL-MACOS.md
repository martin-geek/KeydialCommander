# Keydial Commander for macOS

The macOS preview runs the Commander editor in your browser and uses a
foreground process to remap a single Huion Keydial Mini (K20). Profiles,
shortcut capture, macros and binding import/export use the same editor and
YAML format as the Linux version.

## Build and run

Use macOS 11 or later, a supported Python 3 with pip, Node.js 24 or later,
and the Apple Command Line Tools (`xcode-select --install`). Run these commands
from the checkout in Terminal:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
npm --prefix web ci
npm --prefix web run build
.venv/bin/python -m pip install .
.venv/bin/huion-keydial-mini --open
```

The editor defaults to [127.0.0.1:8137](http://127.0.0.1:8137).
Leave Terminal running while you use the keypad. Press Control+C in Terminal
to stop remapping and release the keypad. Profiles are saved under
`~/.config/huion-keydial-mini/profiles/`.

## Connect the keypad

1. Pair the K20 in **System Settings → Bluetooth**, or connect it with a USB
   data cable.
2. In **System Settings → Privacy & Security**, enable **Input Monitoring**
   and **Accessibility** for the terminal application you use to run
   Commander. Quit and reopen that terminal, then start Commander again.
3. Use the editor’s **Identify** mode to check the 18 buttons, both dial
   directions, and the dial click. Then assign a shortcut to a button and try
   it in a text editor. For example, Command+A uses `KEY_LEFTMETA+KEY_A`.

If the status shows **Cannot access K20 input**, quit other keypad remappers
or the Huion utility if it controls the K20, then reconnect the keypad.
Commander waits for all expected controls before activating a capture
session. The macOS backend matches Huion vendor ID `0x256c` and K20 product
ID `0x8251`.

**Open URL** uses `/usr/bin/open` with the URL as its argument. **Launch app**
uses `/usr/bin/open` with two arguments, `-a` and the app name. Imported
profiles retain their original key names and command arguments. Edit
platform-specific bindings after import. The key picker lists the keys the
local backend can emit.

The preview builds from source and runs from Terminal. Physical Bluetooth
and USB input, media output, and reconnect behavior still need an end-to-end
test with macOS privacy permissions granted.
