# Folder shortcuts

Add entries to `dock.folders` in `~/.config/omarchy/shell.json`. For example:

```json
"dock": {
  "folders": [
    { "path": "/home/your-user/Documents", "name": "Documents" },
    { "path": "/home/your-user/Work projects", "name": "Projects", "icon": "folder-development" }
  ]
}
```

Keep any existing `dock.pinned` and other dock settings. Each `path` must be
absolute. `name` and `icon` are optional; the last path component is used as
the default name. Without an explicit icon, the dock reads the folder icon
from Nautilus/GIO and falls back to the theme's `folder` icon. Icons refresh on
load and periodically while the dock is open. Duplicate paths are shown once.
Left-click the icon to open the folder in the system's default file manager.
Right-click to see its name and path, remove it from the dock, or open an item
from its scrollable list of subfolders and files. The name/path row also opens
the folder itself. Missing directories stay visible, with a notification when
clicked, and their context menu reports the folder as unavailable. Drag icons to reorder them;
the resulting mixed app/folder order is stored in `dock.order`. Applications
remain in `dock.pinned`; folder paths never become app IDs.
The dock groups pinned apps, running unpinned apps, and folders in that order,
with a divider only between groups that are present. Dragging a running app
into the pinned section pins it; folders can be reordered within their group.
Reordering running apps within the unpinned group keeps them unpinned. Pinned
apps stay within their group when dragged, and unpinning remains a menu action.
Only a visible pinned app slot pins an internally dragged app; when that group
is empty, use the app grid or “Keep in dock” to pin an app. The drag preview
uses the same group limits as the final placement. Order and pins are saved
together, retaining entries that are not currently visible or installed.
Dragging an app out of the app grid pins it at the marked slot, which stays
within the pinned group (or at its start when empty), inside the dock instead
of pushing its ends past the background.

With the dock visible, drag one local folder from Nautilus onto it to add a
shortcut automatically using the folder's name. While a valid folder hovers,
the dock reserves the slot it will occupy and outlines itself in the accent
color; files, remote locations, and multiple selections show the dock in the
error color and are not registered.

Dragging a file onto an app icon opens it in that app, provided the entry
declares a file argument in its `Exec` line. Dropping a file onto a folder
shortcut moves it into that folder and never overwrites an existing name.
Anything else is rejected with a notification.

## Tests

After editing QML or imported JavaScript, if the dock still behaves as before,
run `omarchy restart shell`. The plugin rescan can retain cached components
even when the shell logs that the local plugin was reloaded.

Use Node.js 22.12+ (22.x), 24.x, or 26+ and npm to run the regression tests:

```sh
npm ci
npm test
npm run test:watch
```

Vitest is a development dependency. npm manages development commands; the
plugin runs in Quickshell. `npm test` and `npm run test:js` run once;
`npm run test:watch` reruns tests when test files or their QML/model inputs change.

The tests execute the positioning functions and drop handler extracted from
`src/DockWindow.qml`, plus reorder and pin handlers from `src/Dock.qml`. They cover
group constraints, explicit pinning, preserved hidden entries, configuration
reloads, slot boundaries, padding, dividers, dock positions,
font scales, target consistency, and insertion/reordering behavior without
launching the desktop shell. Visual Wayland drag-and-drop still needs a manual
check with temporary files.

See [the testing strategy](specs/005-testing-strategy.md) for the native
QML/Quickshell suites and additional Python scenarios planned next.

### Python and shell helpers

`src/folders.py` contains the importable filesystem operations and their CLI.
`src/folders.sh` calls this sibling file and handles configuration and notifications;
keep both files together when installing the plugin. Running the plugin requires
only the Python standard library, not pytest.

Install test dependencies in a local virtual environment and run the Python suite:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
npm run test:python
```

`requirements-dev.in` declares the test dependencies; `requirements-dev.txt`
pins their resolved versions. The Python tests cover folder URLs, icon metadata,
listing order and limits, move results, and shell dispatch/configuration using
temporary directories and stubbed notifications. They do not access the real
shell configuration. `npm test` continues to run the JavaScript suite.

This extraction preserves the existing move behavior. Atomic protection against
concurrent destination creation remains tracked in
[spec 004](specs/004-move-without-overwrite.md).

## Project layout

Runtime QML, JavaScript, Python, and shell files live together in `src/`.
`manifest.json` stays at the plugin root and loads `src/Dock.qml`. Tests live
in `tests/js/` and `tests/python/`; test configuration remains at the root.
