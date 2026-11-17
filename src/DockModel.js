// The dock's state that does not need Quickshell: where it sits, which apps it
// shows, and which window a click brings forward.

var POSITIONS = ["top", "bottom", "left", "right"]

function normalizePosition(value) {
  var position = String(value || "").trim().toLowerCase()
  return POSITIONS.indexOf(position) >= 0 ? position : "bottom"
}

function isVertical(position) {
  var normalized = normalizePosition(position)
  return normalized === "left" || normalized === "right"
}

// No lower scale limit: even very crowded docks must fit without scrolling.
function fitScale(availableLength, naturalLength) {
  if (!(availableLength > 0) || !(naturalLength > 0)) return 1
  return Math.min(1, availableLength / naturalLength)
}

function normalizeId(value) {
  var id = String(value || "").trim()
  if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
  return id
}

function pinnedIds(dockConfig, defaultsConfig) {
  var source = dockConfig && Array.isArray(dockConfig.pinned) ? dockConfig.pinned
    : (defaultsConfig && Array.isArray(defaultsConfig.pinned) ? defaultsConfig.pinned : [])
  var ids = []
  for (var i = 0; i < source.length; i++) {
    var id = normalizeId(source[i])
    if (id && ids.indexOf(id) === -1) ids.push(id)
  }
  return ids
}

// Folder shortcuts are separate from desktop entries. Only absolute paths are
// accepted; a missing directory is kept so the user can repair its path later.
function folderItems(dockConfig) {
  var source = dockConfig && Array.isArray(dockConfig.folders) ? dockConfig.folders : []
  var items = []
  var seen = {}
  for (var i = 0; i < source.length; i++) {
    var folder = source[i]
    if (!folder || typeof folder !== "object" || Array.isArray(folder) || typeof folder.path !== "string") continue
    var path = folder.path.replace(/\/+$/, "") || "/"
    if (path.charAt(0) !== "/" || seen[path]) continue
    seen[path] = true
    var name = typeof folder.name === "string" ? folder.name.trim() : ""
    var icon = typeof folder.icon === "string" ? folder.icon.trim() : ""
    items.push({ type: "folder", key: "folder:" + path, path: path,
      name: name || (path === "/" ? "/" : path.slice(path.lastIndexOf("/") + 1)),
      icon: icon, pinned: true, windows: [] })
  }
  return items
}

function configuredOrder(dockConfig) {
  return dockConfig && Array.isArray(dockConfig.order)
    ? dockConfig.order.filter(function(key) { return typeof key === "string" }) : []
}

// Only app windows on regular workspaces belong in the dock. Helpers without a
// visible desktop entry, such as the agent window, and anything parked on a
// special workspace, such as the scratchpad, stay out of it. A minimized window
// always belongs, entry or not, since the dock is the only way back to it.
function isDockWindow(window) {
  if (!window || !window.key) return false
  if (window.minimized === true) return true
  return window.hasEntry === true && window.workspaceId >= 1
}

// Minimizing moves a window to this special workspace, and the dock brings it
// back.
var MINIMIZED_WORKSPACE = "special:minimized"

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

// Omarchy tags minimized windows with the workspace they came from. Unlike
// local session state, this also covers the titlebar button and Super+M.
function minimizedFromTags(tags) {
  var list = tags || []
  for (var i = 0; i < list.length; i++) {
    var match = /^omarchy-minimized-from-([1-9][0-9]*)$/.exec(String(list[i]))
    if (match) return Number(match[1])
  }
  return -1
}

function effectiveWorkspaceId(window) {
  if (!window) return -1
  return window.minimized ? (window.minimizedFrom || -1) : window.workspaceId
}

function remoteWorkspaceIds(windows, currentWorkspaceId) {
  var ids = []
  for (var i = 0; i < (windows || []).length; i++) {
    var id = effectiveWorkspaceId(windows[i])
    if (id >= 1 && id !== currentWorkspaceId && ids.indexOf(id) < 0) ids.push(id)
  }
  return ids.sort(function(a, b) { return a - b })
}

// Omarchy gives each monitor a block of ten Hyprland workspace IDs, but its
// bar shows slots 1–9 and 0. Keep the internal IDs for navigation only.
function workspaceLabel(id) {
  if (!(id >= 1)) return ""
  var slot = (id - 1) % 10 + 1
  return slot === 10 ? "0" : String(slot)
}

// Does a Hyprland client occupy the dock's visible rectangle? Ignore a tiny
// edge-only contact so window borders do not make the dock flicker.
function overlapsDock(client, dock) {
  if (!client || client.hidden || client.mapped === false || !client.at || !client.size || !dock) return false
  var x = Number(client.at[0]), y = Number(client.at[1])
  var width = Number(client.size[0]), height = Number(client.size[1])
  if (!isFinite(x) || !isFinite(y) || !(width > 0) || !(height > 0)) return false
  var inset = 2
  return x < dock.x + dock.width - inset && x + width > dock.x + inset
    && y < dock.y + dock.height - inset && y + height > dock.y + inset
}

// A terminal app's window carries the app id its launcher gave the terminal,
// which no desktop entry names as its class. The entry that passes that app id
// claims it, and so does a terminal entry for the command Omarchy's TUI
// launcher named it after (org.omarchy.nvim for nvim). Entries are
// { id, execString, command, runInTerminal }.
function claimingEntryId(appId, entries) {
  var id = String(appId || "")
  if (!id) return ""
  var list = entries || []
  var flag = "--app-id=" + id
  for (var i = 0; i < list.length; i++) {
    var words = String(list[i].execString || "").split(/\s+/)
    if (words.indexOf(flag) >= 0) return list[i].id
  }
  if (id.indexOf("org.omarchy.") !== 0) return ""
  var command = id.slice("org.omarchy.".length)
  for (var j = 0; j < list.length; j++) {
    var program = String((list[j].command || [])[0] || "")
    if (list[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command) return list[j].id
  }
  return ""
}

// Pinned apps come first, in pin order, whether or not they run. Running apps
// that are not pinned follow in the order their first window appeared. Each
// window is { key, hasEntry, workspaceId, ... } where key is the desktop id of
// the entry that claims it.
function buildItems(pinned, windows) {
  var items = []
  var byKey = {}

  function itemFor(key, isPinned) {
    if (!byKey[key]) {
      byKey[key] = { type: "app", key: key, pinned: isPinned, windows: [] }
      items.push(byKey[key])
    }
    return byKey[key]
  }

  for (var i = 0; i < (pinned || []).length; i++) {
    if (pinned[i]) itemFor(pinned[i], true)
  }

  for (var j = 0; j < (windows || []).length; j++) {
    var window = windows[j]
    if (isDockWindow(window)) itemFor(window.key, false).windows.push(window)
  }

  return items
}

// Puts the items in the dock's own order, which the dock keeps for the
// session: an app keeps its slot while it stays in the dock, and an app that
// joins goes at the end. Items the order does not know yet follow in the order
// buildItems gave them.
function orderItems(items, order) {
  var byKey = {}
  for (var i = 0; i < (items || []).length; i++) byKey[items[i].key] = items[i]
  var result = []
  var placed = {}
  for (var j = 0; j < (order || []).length; j++) {
    var key = order[j]
    if (byKey[key] && !placed[key]) {
      result.push(byKey[key])
      placed[key] = true
    }
  }
  for (var k = 0; k < (items || []).length; k++) {
    if (!placed[items[k].key]) result.push(items[k])
  }
  return result
}

// Keep the three kinds of dock entry together. OrderItems still determines
// the order within each group, including drag reordering of pinned entries.
function itemGroup(item) {
  return item.type === "folder" ? 2 : item.pinned ? 0 : 1
}

function groupItems(items) {
  var groups = [[], [], []]
  for (var i = 0; i < (items || []).length; i++) groups[itemGroup(items[i])].push(items[i])
  return groups[0].concat(groups[1], groups[2])
}

// Classify the destination before moving anything. Only an existing pinned
// app slot expresses pinning intent; folders and pinned apps stay in their group.
function moveTarget(items, fromIndex, toIndex) {
  if (!items || !items[fromIndex] || !items[toIndex]) return null
  var group = itemGroup(items[fromIndex])
  var pin = group === 1 && itemGroup(items[toIndex]) === 0
  var first = fromIndex, last = fromIndex
  for (var i = 0; i < items.length; i++) {
    var candidate = itemGroup(items[i])
    if (candidate === group || (group === 1 && candidate === 0)) {
      first = Math.min(first, i)
      last = Math.max(last, i)
    }
  }
  return { index: Math.max(first, Math.min(last, toIndex)), pin: pin }
}

// Zero-based indexes of items preceded by a different, non-empty group.
function dividersBefore(items) {
  var result = []
  for (var i = 1; i < (items || []).length; i++)
    if (itemGroup(items[i]) !== itemGroup(items[i - 1])) result.push(i)
  return result
}

// The order with key moved to index, counted once key has left its old slot.
function orderWithKeyAt(order, key, index) {
  var keys = (order || []).filter(function(other) { return other !== key })
  keys.splice(Math.max(0, Math.min(keys.length, index)), 0, key)
  return keys
}

// Where a dragged icon lands: its own slot moved by however many slots the
// pointer has travelled, kept within the dock.
function dropIndex(fromIndex, offset, slotSize, count) {
  if (count <= 0 || !(slotSize > 0)) return fromIndex
  var target = fromIndex + Math.round(offset / slotSize)
  return Math.max(0, Math.min(count - 1, target))
}

// The pins to save for the dock's order: the pinned apps in that order, then
// pins the dock is not showing, because their app is not installed, as they
// were. pinned holds the pinned desktop ids as keys.
function pinsInOrder(order, pinned, allPinned) {
  var result = (order || []).filter(function(key) { return pinned[key] === true })
  for (var i = 0; i < (allPinned || []).length; i++) {
    if (result.indexOf(allPinned[i]) === -1 && (order || []).indexOf(allPinned[i]) === -1) result.push(allPinned[i])
  }
  return result
}

// The window a click acts on: first the focused local window (to minimize),
// then other local windows, then remote ones. A minimized window belongs to
// its tagged original workspace. Visible windows precede minimized ones within
// each group. Windows are { workspaceId, minimized, minimizedFrom, activated }.
function pickWindow(windows, workspaceId) {
  var list = windows || []
  if (list.length === 0) return -1

  function rank(window) {
    var local = effectiveWorkspaceId(window) === workspaceId
    return (local ? 0 : 2) + (window.minimized ? 1 : 0)
  }

  var order = list.map(function(window, index) { return index })
  order.sort(function(a, b) { return rank(list[a]) - rank(list[b]) || a - b })

  for (var i = 0; i < order.length; i++)
    if (list[order[i]].activated && !list[order[i]].minimized
        && effectiveWorkspaceId(list[order[i]]) === workspaceId) return order[i]
  return order[0]
}


if (typeof module !== "undefined") {
  module.exports = {
    normalizePosition: normalizePosition,
    isVertical: isVertical,
    fitScale: fitScale,
    normalizeId: normalizeId,
    pinnedIds: pinnedIds,
    folderItems: folderItems,
    configuredOrder: configuredOrder,
    isDockWindow: isDockWindow,
    isMinimizedWorkspace: isMinimizedWorkspace,
    minimizedFromTags: minimizedFromTags,
    effectiveWorkspaceId: effectiveWorkspaceId,
    remoteWorkspaceIds: remoteWorkspaceIds,
    workspaceLabel: workspaceLabel,
    overlapsDock: overlapsDock,
    claimingEntryId: claimingEntryId,
    buildItems: buildItems,
    orderItems: orderItems,
    itemGroup: itemGroup,
    groupItems: groupItems,
    moveTarget: moveTarget,
    dividersBefore: dividersBefore,
    orderWithKeyAt: orderWithKeyAt,
    dropIndex: dropIndex,
    pinsInOrder: pinsInOrder,
    pickWindow: pickWindow
  }
}
