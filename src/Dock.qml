import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "DockModel.js" as DockModel
import "WorkspaceModel.js" as WorkspaceModel

// An app and folder dock for regular workspaces.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property var appLibrary: localAppLibrary
  property var dockConfig: ({})
  property var defaultDockConfig: ({})
  function readDockConfig(raw) {
    try {
      var config = JSON.parse(String(raw || ""))
      return config && config.dock && typeof config.dock === "object" ? config.dock : ({})
    } catch (e) {
      return ({})
    }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    onLoaded: root.dockConfig = root.readDockConfig(text())
    onFileChanged: reload()
  }
  FileView {
    path: Quickshell.env("OMARCHY_PATH") + "/config/omarchy/shell.json"
    onLoaded: root.defaultDockConfig = root.readDockConfig(text())
  }
  readonly property string position: DockModel.normalizePosition(dockConfig.position)
  readonly property bool vertical: DockModel.isVertical(position)
  readonly property bool autohide: dockConfig.autohide === true
  readonly property bool alwaysVisible: dockConfig.alwaysVisible === true
  readonly property bool showWorkspaceButton: dockConfig.showWorkspaceButton === true

  function windowAddress(appWindow) {
    var address = String(appWindow && appWindow.address || "")
    return address && address.indexOf("0x") !== 0 ? "0x" + address : address
  }

  LocalAppLibrary { id: localAppLibrary }

  readonly property var notificationCounts: notificationBadges.counts
  NotificationBadges {
    id: notificationBadges
    focusedAppId: {
      var top = ToplevelManager.activeToplevel
      while (top && top.parent) top = top.parent
      var entry = top && top.appId ? root.entryForAppId(top.appId) : null
      return entry ? entry.id : ""
    }
  }

  // Configured order contains desktop ids and folder:<absolute path> keys.
  // Session changes show immediately while the config write catches up.
  property var pendingOrder: null
  readonly property var order: pendingOrder || DockModel.configuredOrder(dockConfig)

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onDockConfigChanged: {
    pendingPins = null
    pendingOrder = null
  }

  readonly property var folders: DockModel.folderShortcuts(DockModel.folderItems(dockConfig), Quickshell.env("HOME"))
  property var folderIcons: ({})
  property var pendingFolderIcons: []
  property string folderIconPath: ""

  function refreshFolderIcons() {
    var next = {}
    var paths = []
    for (var i = 0; i < root.folders.length; i++) {
      var path = root.folders[i].path
      if (root.folderIcons[path] !== undefined) next[path] = root.folderIcons[path]
      if (!root.folders[i].icon) paths.push(path)
    }
    root.folderIcons = next
    root.pendingFolderIcons = paths
    root.readNextFolderIcon()
  }

  function readNextFolderIcon() {
    if (folderIconProc.running || root.pendingFolderIcons.length === 0) return
    root.folderIconPath = root.pendingFolderIcons.shift()
    folderIconProc.command = [root.folderScriptPath(), "icon", root.folderIconPath]
    folderIconProc.running = true
  }

  onFoldersChanged: refreshFolderIcons()

  Timer {
    interval: 60000
    repeat: true
    running: root.folders.length > 0
    onTriggered: root.refreshFolderIcons()
  }

  Process {
    id: folderIconProc
    stdout: StdioCollector {
      onStreamFinished: {
        var path = root.folderIconPath
        if (!root.folders.some(function(folder) { return folder.path === path && !folder.icon })) return
        var next = Object.assign({}, root.folderIcons)
        next[path] = text.trim()
        root.folderIcons = next
      }
    }
    onExited: Qt.callLater(root.readNextFolderIcon)
  }

  // Entries that can claim a terminal app's window: those run in a terminal,
  // and those that hand the terminal an app id of their own.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // Share the compositor snapshot with the workspace overview, including
  // ordinary windows that do not have a matching desktop entry.
  readonly property var appWindows: {
    var appsRevision = DesktopEntries.applications.values.length
    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || toplevel.parent) continue
      var entry = toplevel.appId ? root.entryForAppId(toplevel.appId) : null
      var workspace = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        minimizedFrom: DockModel.minimizedFromTags(toplevels[i].lastIpcObject ? toplevels[i].lastIpcObject.tags : []),
        address: toplevels[i].address,
        title: String((toplevels[i].lastIpcObject && toplevels[i].lastIpcObject.title)
          || toplevel.title || (entry && entry.name) || toplevel.appId || ""),
        toplevel: toplevel
      })
    }

    return windows
  }
  readonly property var workspaceWindows: appWindows.filter(function(window) {
    return window.minimized || WorkspaceModel.regularId(window.workspaceId)
  })
  readonly property var workspaceMonitors: Hyprland.monitors.values.map(function(monitor) {
    return { name: monitor.name, activeId: monitor.activeWorkspace ? monitor.activeWorkspace.id : -1 }
  })
  readonly property var workspaceCatalog: WorkspaceModel.catalog(Hyprland.workspaces.values.map(function(space) {
    return { id: space.id, monitor: space.monitor ? space.monitor.name : "" }
  }), workspaceMonitors, workspaceWindows)

  // Uninstalled pins and windows without desktop entries stay out of the strip.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })
    var windows = root.appWindows.filter(function(window) { return !!window.key })
    return DockModel.groupItems(DockModel.orderItems(DockModel.buildItems(pinned, windows).concat(root.folders), root.order))
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.items.length; i++) byKey[root.items[i].key] = root.items[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  onItemsChanged: settleLaunches()

  // Each launch gets a fresh serial so the icon can replay its one-shot hop,
  // even when a second new-window request arrives before the first completes.
  property var launches: ({})
  property int launchSerial: 0
  readonly property int launchTimeout: 10000

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var windows = item ? item.windows.length : 0
      if (windows > launch.windows || now - launch.at > root.launchTimeout) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function entryFor(item) {
    return item && item.type !== "folder" ? DesktopEntries.byId(item.key) : null
  }

  function iconFor(item) {
    if (item && item.type === "folder") {
      var icon = item.icon || root.folderIcons[item.path] || ""
      if (icon && (icon.indexOf("file://") === 0 || icon.charAt(0) === "/" || Quickshell.hasThemeIcon(icon)))
        return root.appLibrary.iconSource(icon)
      return root.appLibrary.iconSource("folder")
    }
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    return root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
  }

  function launch(item) {
    if (item && item.builtin === "trash") {
      Util.execDetached("gio open trash:///")
      return
    }
    if (item && item.type === "folder") {
      var path = Util.shellQuote(item.path)
      Util.execDetached("if [ -d " + path + " ]; then xdg-open " + path
        + "; else notify-send 'Carismatic Dock' " + Util.shellQuote("Folder unavailable: " + item.path) + "; fi")
      return
    }
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length, serial: ++root.launchSerial }
    root.launches = next
    root.launchEntry(entry)
  }

  function launchEntry(entry) {
    if (entry && root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
  }

  // A file dropped on an app icon opens in that app; dropped on a folder it
  // moves into it, never overwriting.
  function openDroppedFile(item, path) {
    if (!item || !path || item.builtin === "trash") return
    if (item.type === "folder") {
      Util.execDetached(root.folderCommand() + " move " + Util.shellQuote(path) + " " + Util.shellQuote(item.path))
      return
    }
    var entry = entryFor(item)
    if (entry && root.appLibrary) root.appLibrary.launchWithFile(entry.id, path, entry.name)
  }

  function activate(item, workspaceId) {
    if (!item) return
    if (item.type === "folder") { root.launch(item); return }
    if (item.windows.length === 0) {
      root.launch(item)
      return
    }
    var index = DockModel.pickWindow(item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized,
        minimizedFrom: window.minimizedFrom, activated: window.toplevel.activated }
    }), workspaceId)
    if (index < 0) return
    root.activateWindow(item.windows[index], workspaceId)
  }

  function activateWindow(selected, workspaceId) {
    if (!selected) return
    var targetWorkspaceId = DockModel.effectiveWorkspaceId(selected)
    if (targetWorkspaceId === workspaceId && selected.toplevel.activated && !selected.minimized)
      root.minimize(selected, workspaceId)
    else root.bringForward(selected, targetWorkspaceId)
  }

  function focusManagedWindow(selected, currentId) {
    if (!selected) return
    var target = DockModel.effectiveWorkspaceId(selected)
    root.bringForward(selected, WorkspaceModel.regularId(target) ? target : currentId)
  }

  function managedWindow(address) {
    if (!address) return null
    return root.workspaceWindows.find(function(window) {
      return WorkspaceModel.address(window.address) === address
    }) || null
  }

  function moveManagedWindow(address, targetId, targetMonitor) {
    var target = root.workspaceCatalog.byId[targetId]
    if (!target || !target.present || target.monitor !== targetMonitor) return
    var expression = WorkspaceModel.moveExpression(root.managedWindow(address), targetId)
    if (expression) Quickshell.execDetached(["hyprctl", "dispatch", expression])
  }

  function focusManagedWorkspace(id) {
    var target = root.workspaceCatalog.byId[id]
    if (!WorkspaceModel.regularId(id) || !target || !target.present) return
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "' + id + '" })'])
  }

  function minimize(appWindow, workspaceId) {
    var address = root.windowAddress(appWindow)
    if (!address || !(workspaceId >= 1)) return
    // The Omarchy command tags the origin and focuses the old workspace after
    // moving the window. Moving it ourselves skips both steps.
    Util.execDetached("omarchy-hyprland-window-minimize " + Util.shellQuote(address))
  }

  // A window the dock brings forward lands on top of the others, focused; a
  // minimized one first comes back to the workspace in front of the user.
  function bringForward(window, workspaceId) {
    var address = WorkspaceModel.address(window.address)
    if (!address) {
      window.toplevel.activate()
      return
    }
    var target = "window = \"address:" + address + "\""
    var steps = []
    var after = []
    if (window.minimized) {
      if (!(workspaceId >= 1)) return
      // A restored window is simply there again, without animating in.
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspaceId + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var command = steps.map(dispatch).join(" && ")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    Util.execDetached(command)
  }

  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  function openApps() {
    missionControl.close()
    appGrid.open()
  }

  function openMissionControl(screen) {
    if (appGrid.opened) appGrid.close()
    missionControl.open(screen)
  }

  function managedWindowIcon(window) {
    var entry = window && window.key ? DesktopEntries.byId(window.key) : null
    return root.appLibrary.iconSource(entry && entry.icon ? entry.icon : "application-x-executable")
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves a shortcut or app to a slot, persisting the mixed order and the
  // desktop-only pinned list in one atomic config update.
  function placeAt(key, index, visibleKeys, pin) {
    if (!key) return
    var keys = visibleKeys || root.shownKeys()
    var visibleOrder = DockModel.orderWithKeyAt(keys, key, index)
    root.pendingOrder = visibleOrder.concat(root.order.filter(function(other) {
      return visibleOrder.indexOf(other) < 0
    }))
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    if (pin && key.indexOf("folder:") !== 0) pinned[key] = true
    root.saveOrder(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  function folderScriptPath() {
    return Quickshell.env("HOME") + "/.config/omarchy/plugins/carismatic-dock/src/folders.sh"
  }

  function folderCommand() {
    return Util.shellQuote(root.folderScriptPath())
  }

  function setAlwaysVisible(enabled) {
    Util.execDetached(root.folderCommand() + " always-visible " + (enabled ? "on" : "off"))
  }

  function saveOrder(pins) {
    root.pendingPins = pins
    Util.execDetached(root.folderCommand() + " order " + Util.shellQuote(JSON.stringify(root.order))
      + " " + Util.shellQuote(JSON.stringify(pins)))
  }

  function removeFolder(item) {
    if (!item || item.type !== "folder" || item.fixed) return
    root.pendingOrder = root.order.filter(function(key) { return key !== item.key })
    Util.execDetached(root.folderCommand() + " remove " + Util.shellQuote(item.path))
  }

  function moveItem(fromIndex, toIndex, visibleKeys) {
    var keys = visibleKeys || root.shownKeys()
    var items = keys.map(function(key) {
      return root.itemFor(key)
    })
    var target = DockModel.moveTarget(items, fromIndex, toIndex)
    if (target && fromIndex !== target.index) root.placeAt(keys[fromIndex], target.index, keys, target.pin)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index, visibleKeys) {
    var keys = visibleKeys || root.shownKeys()
    var pinCount = keys.filter(function(other) { return other.indexOf("folder:") !== 0 && root.isPinned(other) }).length
    index = Math.max(0, Math.min(pinCount, index))
    var from = keys.indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index, keys, true)
  }

  // Keeping an app puts it at the end of the pinned group; taking one out
  // leaves it in its slot while it still runs.
  function setPinned(key, pinned, visibleKeys) {
    if (!key) return
    if (pinned) {
      var keys = visibleKeys || root.shownKeys()
      var pinCount = keys.filter(function(other) { return other.indexOf("folder:") !== 0 && root.isPinned(other) }).length
      root.pinAt(key, pinCount, keys)
    } else {
      root.pendingPins = root.pinnedKeys.filter(function(other) { return other !== key })
      Util.execDetached("omarchy-dock unpin " + Util.shellQuote(key))
    }
  }

  // Each workspace's layout is read once and cached. It only changes through
  // the layout commands, which ask the dock to refresh, or a config reload.
  property var modes: ({})
  property var pendingModes: []
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function isFloating(workspaceId) {
    return root.modes[workspaceId] === "floating"
  }

  function readMode(workspaceId) {
    if (!(workspaceId >= 1) || root.modes[workspaceId] !== undefined) return
    if (root.pendingModes.indexOf(workspaceId) === -1) root.pendingModes.push(workspaceId)
    root.readNextMode()
  }

  function readNextMode() {
    if (modeProc.running || root.pendingModes.length === 0) return
    root.modeProcWorkspace = root.pendingModes.shift()
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(root.modeProcWorkspace)]
    modeProc.running = true
  }

  function refresh() {
    root.modes = ({})
    root.pendingModes = []
    root.modeGeneration++
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].activeWorkspace) root.readMode(monitors[i].activeWorkspace.id)
    }
    // Read the rest ahead of time, so the dock shows or hides the moment the
    // user switches to one.
    var workspaces = Hyprland.workspaces.values
    for (var j = 0; j < workspaces.length; j++) root.readMode(workspaces[j].id)
  }

  Component.onCompleted: {
    refresh()
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        // A read that started before a refresh may predate the change.
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        var next = Object.assign({}, root.modes)
        next[root.modeProcWorkspace] = mode
        root.modes = next
      }
    }
    // Deferred: the process still reports running while it signals exit.
    onExited: Qt.callLater(root.readNextMode)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "configreloaded") root.refresh()
      // Hyprland's window and workspace lists do not follow fullscreen on
      // their own.
      else if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      } else if (name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      } else if (name === "movewindow" || name === "movewindowv2" || name === "tagwindow") {
        // Origin tags and special-workspace membership must arrive together
        // for minimized windows to show on their original workspace.
        Hyprland.refreshToplevels()
      }
    }
  }

  ShellIpc {
    target: "omarchy.dock"

    // The layout commands call this after changing a workspace's mode.
    function refresh(): void { root.refresh() }
    function apps(): void {
      missionControl.close()
      appGrid.toggle()
    }
    function workspaces(): void {
      if (missionControl.shown) missionControl.close()
      else root.openMissionControl(null)
    }
  }

  // An app dragged out of the app grid: the grid holds the pointer and
  // reports where it is, and the dock on that screen shows where it would land.
  function dockOn(screen) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) return windows[i]
    }
    return null
  }

  function moveExternalDrag(screen, x, y) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) windows[i].moveExternalDrag(x, y)
      else windows[i].endExternalDrag()
    }
  }

  function dropExternalDrag(screen, x, y, key) {
    var target = root.dockOn(screen)
    if (target) target.dropExternalDrag(x, y, key)
    root.endExternalDrag()
  }

  function endExternalDrag() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].endExternalDrag()
  }

  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData

        screen: modelData
        dock: root
      }
    }
  }

  AppGrid {
    id: appGrid
    appLibrary: root.appLibrary
    dock: root
  }

  MissionControl {
    id: missionControl
    dock: root
  }
}
