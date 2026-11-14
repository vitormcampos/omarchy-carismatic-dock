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
The icon opens the folder as a stack listing its contents; the first row opens
the directory itself in the system's default file manager. Missing directories
stay visible, with a notification when clicked, and their stack reports the
folder as unavailable. Right-click a folder to see its path or remove it from
the dock. Drag icons to reorder them;
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
`DockWindow.qml`, plus reorder and pin handlers from `Dock.qml`. They cover
group constraints, explicit pinning, preserved hidden entries, configuration
reloads, slot boundaries, padding, dividers, dock positions,
font scales, target consistency, and insertion/reordering behavior without
launching the desktop shell. Visual Wayland drag-and-drop still needs a manual
check with temporary files.

See [the testing strategy](specs/005-testing-strategy.md) for the planned native
QML/Quickshell and Python suites, their scope, and implementation order.
