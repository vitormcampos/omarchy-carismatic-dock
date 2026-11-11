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
The icon opens the directory using the system's default file manager. Missing
directories stay visible, with a notification when clicked. Right-click a
folder to see its path or remove it from the dock. Drag icons to reorder them;
the resulting mixed app/folder order is stored in `dock.order`. Applications
remain in `dock.pinned`; folder paths never become app IDs.
The dock groups pinned apps, running unpinned apps, and folders in that order,
with a divider only between groups that are present. Dragging a running app
into the pinned section pins it; folders can be reordered within their group.
Dragging an app out of the app grid pins it at the marked slot, which stays
inside the dock instead of pushing its ends past the background.

With the dock visible, drag one local folder from Nautilus onto it to add a
shortcut automatically using the folder's name. While a valid folder hovers,
the dock reserves the slot it will occupy and outlines itself in the accent
color; files, remote locations, and multiple selections show the dock in the
error color and are not registered.
