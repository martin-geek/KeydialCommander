# Keydial Commander for macOS changelog

`VERSION` sets the Finder, Setup, menu bar, and disk image version. Update it
and add an entry here for each macOS release.

## 1.3.6

- Adds a saved **Show In** setting for the menu bar, Dock, or both.
- Keeps remapping active after the editor window closes.

## 1.3.5

- Adds an opt-in USB tablet mode for the K20, so wired remapping can work
  when macOS denies exclusive keyboard access. Power-cycle the K20 to restore
  its factory shortcuts.
- Highlights each physical press on the keypad picture, including controls
  with no shortcut assigned.

## 1.3.4

- Distinguishes macOS denying exclusive keypad access from a connection or
  privacy settings problem. Falls back to Identify when macOS allows shared
  reads. Remapping stays disabled in this mode because the factory inputs
  still reach the active app.

## 1.3.3

- Setup shows the installer version and the version in Applications. It
  verifies the staged bundle, replaces the app and its bundled service
  together, and reports the result. It rejects an older installer when a
  newer version is already in Applications.
- Commander opens permission setup when its service reports missing access.
  The setup window explains what each permission does and links to its
  macOS settings.
- The menu bar uses a monochrome keypad icon and shows the running version.
- The build script supports Developer ID signing and Apple notarization.

## 1.3.2

- Recognizes the wired K20 and displays its USB connection.
- Installs in the main Applications folder and distinguishes a busy keypad
  from other capture failures.

## 1.3.1

- Ships the native editor, graphical Setup, rotating keypad artwork, mapping
  preview, menu bar controls, appearance settings, and per-app profiles.
