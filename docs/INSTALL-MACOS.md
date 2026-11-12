# Keydial Commander for macOS

## Install the desktop app

The desktop app uses a native macOS window and bundles the remapping engine.
Open the Keydial Commander disk image, double-click **Keydial Commander Setup**,
then click **Install** and **Open App**. Setup installs into your account’s
`~/Applications` folder. You can open Commander from Spotlight after that.
The desktop build targets macOS 14 or later and is built for the Mac’s CPU
architecture.

Pair the Huion Keydial Mini (K20) in Bluetooth settings or connect it with a USB
data cable. In Commander, click **Permissions…** when prompted. Enable
**Accessibility** and **Input Monitoring** for Keydial Commander in
**System Settings → Privacy & Security**, then quit and reopen Commander.
Quit the earlier Terminal preview before starting the desktop app.

Click the circular arrow above the keypad to rotate it 90° clockwise. The app
remembers the orientation, and each physical button keeps its binding. Assigned
actions appear on the keycaps. Hover over a control for its full mapping.

The Commander icon in the macOS menu bar opens a translucent panel with the
editor, preview, rotation, profile controls, appearance, and Quit. Choose
**System**, **Light**, or **Dark** in that panel or in the **Keydial** menu.

Select a keypad control and choose **Show Settings Preview** to bind a visual
guide to the active profile. You can also open the guide from the menu bar.
Use **Manage Profiles → Export Profile** or **Import Profile** to move mappings
between installations as YAML files. Edits made with **Save** are stored
in the current profile. In **App Profiles**, add a Mac application and choose
which profile it should use when frontmost. Set a fallback for all other apps.

The status area shows Bluetooth in blue or a USB connector when a remapping
session uses that connection. If macOS does not supply the Bluetooth battery
level, use the **Read Bluetooth Battery** button to authorize reading the
standard Battery Service. The percentage and charging symbol depend on
telemetry from the keypad. A USB connection by itself does not indicate charging.

To uninstall, quit Commander, reopen **Keydial Commander Setup** from the disk
image, and choose **Uninstall…**. Setup moves the installed app to the Trash
and keeps your saved profiles and orientation setting.

## Build the disk image

From a macOS development checkout with Python 3 and the Apple Command Line
Tools, run:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip setuptools wheel
.venv/bin/python -m pip install -e . 'pyinstaller>=6,<7'
bash packaging/macos/build.sh
```

The disk image is written under `dist/`. This build uses local ad hoc code
signing. Distribution to other Macs requires Developer ID signing and Apple
notarization for normal Gatekeeper acceptance.

## Optional browser preview

The earlier browser preview is still available for development. Both macOS
editors use the same profile files.

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

Physical Bluetooth and USB input, media output, and reconnect behavior still
need an end-to-end test with macOS privacy permissions granted.
