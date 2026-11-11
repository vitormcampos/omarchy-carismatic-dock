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

With the dock visible, drag one local folder from Nautilus onto it to add a
shortcut automatically using the folder's name. Files, remote locations, and
multiple selections are not registered.
