import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "DockModel.js" as DockModel

// An app dock for regular workspaces: pinned apps, running apps, and a grid
// of every installed app.
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

  function windowAddress(appWindow) {
    var address = String(appWindow && appWindow.address || "")
    return address && address.indexOf("0x") !== 0 ? "0x" + address : address
  }

  LocalAppLibrary { id: localAppLibrary }

  // The dock's order for the session, as desktop ids, set when the user moves
  // an app: a drag moves it, and keeping it in the dock puts it at the end. An
  // app the order does not know yet goes at the end. Pins are saved in this
  // order.
  property var order: []

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onDockConfigChanged: pendingPins = null

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

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })

    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        minimizedFrom: DockModel.minimizedFromTags(toplevels[i].lastIpcObject ? toplevels[i].lastIpcObject.tags : []),
        address: toplevels[i].address,
        title: String((toplevels[i].lastIpcObject && toplevels[i].lastIpcObject.title)
          || toplevel.title || (entry && entry.name) || toplevel.appId),
        toplevel: toplevel
      })
    }

    return DockModel.orderItems(DockModel.buildItems(pinned, windows), root.order)
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

  // An app launched from the dock pulses its dot until a new window of it
  // shows up, or for ten seconds if none does.
  property var launches: ({})
  readonly property int launchTimeout: 10000

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

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
    return item ? DesktopEntries.byId(item.key) : null
  }

  function iconFor(item) {
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    return root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
  }

  function launch(item) {
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    root.launchEntry(entry)
  }

  function launchEntry(entry) {
    if (entry && root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
  }

  function activate(item, workspaceId) {
    if (!item) return
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
    var address = root.windowAddress(window)
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
    appGrid.open()
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves an app to a slot in the dock's order, pinning it there; the pins are
  // saved in the new order. The index counts the slots once the app has left
  // its own.
  function placeAt(key, index, visibleKeys) {
    if (!key) return
    var keys = visibleKeys || root.shownKeys()
    var visibleOrder = DockModel.orderWithKeyAt(keys, key, index)
    root.order = visibleOrder.concat(root.order.filter(function(other) {
      return visibleOrder.indexOf(other) < 0
    }))
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    pinned[key] = true
    root.savePins(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  // A reorder shows at once; the saved config catches up after.
  function savePins(pins) {
    root.pendingPins = pins
    Util.execDetached("omarchy-dock pinned " + pins.map(function(id) { return Util.shellQuote(id) }).join(" "))
  }

  function moveItem(fromIndex, toIndex, visibleKeys) {
    var keys = visibleKeys || root.shownKeys()
    if (fromIndex !== toIndex) root.placeAt(keys[fromIndex], toIndex, keys)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index, visibleKeys) {
    var keys = visibleKeys || root.shownKeys()
    var from = keys.indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index, keys)
  }

  // Keeping an app in the dock puts it at the end; taking one out leaves it in
  // its slot while it still runs.
  function setPinned(key, pinned, visibleKeys) {
    if (!key) return
    if (pinned) {
      var keys = visibleKeys || root.shownKeys()
      root.placeAt(key, keys.length, keys)
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
    function apps(): void { appGrid.toggle() }
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
}
