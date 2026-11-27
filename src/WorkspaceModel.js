// The compositor's numeric ID is the identity. The short slot is presentation only.
function regularId(id) {
  return Number.isInteger(id) && id > 0 && id <= 2147483647
}

function slot(id) {
  return regularId(id) ? id % 10 : null
}

function address(value) {
  var raw = String(value || "")
  if (!/^(?:0x)?[a-f0-9]{1,16}$/i.test(raw)) return ""
  return "0x" + raw.replace(/^0x/i, "").toLowerCase()
}

function windowWorkspace(window) {
  return window.minimized ? window.minimizedFrom : window.workspaceId
}

function canMove(window) {
  return !!window && !window.minimized && regularId(window.workspaceId) && !!address(window.address)
}

function canDrop(window, space) {
  return canMove(window) && !!space && space.present === true
    && regularId(space.id) && space.id !== window.workspaceId
}

function moveExpression(window, id) {
  if (!canDrop(window, { id: id, present: true })) return ""
  return 'hl.dsp.window.move({ workspace = "' + id + '", window = "address:'
    + address(window.address) + '", follow = false })'
}

function catalog(spaces, monitors, windows) {
  var byId = Object.create(null)
  var active = Object.create(null)
  monitors.forEach(function(monitor) {
    if (regularId(monitor.activeId)) active[monitor.activeId] = monitor.name
  })
  function add(id, monitor, present) {
    if (!regularId(id)) return
    byId[id] = { id: id, monitor: monitor || active[id] || "", present: present,
      active: active[id] !== undefined, fullId: false }
  }
  spaces.forEach(function(space) { add(space.id, space.monitor, true) })
  Object.keys(active).forEach(function(id) {
    if (!byId[id]) add(Number(id), active[id], true)
  })
  windows.forEach(function(window) {
    var id = windowWorkspace(window)
    if (!byId[id]) add(id, "", false)
  })
  var list = Object.keys(byId).map(function(id) { return byId[id] })
  var shortCounts = Object.create(null)
  list.forEach(function(space) {
    var key = space.monitor + "#" + slot(space.id)
    shortCounts[key] = (shortCounts[key] || 0) + 1
  })
  list.forEach(function(space) {
    space.fullId = shortCounts[space.monitor + "#" + slot(space.id)] > 1
  })
  return { list: list, byId: byId }
}

function windowRows(windows) {
  var totals = Object.create(null), positions = Object.create(null)
  function title(window) { return String(window.title || window.key || "") }
  windows.forEach(function(window) {
    var key = title(window)
    totals[key] = (totals[key] || 0) + 1
  })
  return windows.map(function(window) {
    var key = title(window)
    positions[key] = (positions[key] || 0) + 1
    return { kind: "window", window: window,
      title: key + (totals[key] > 1 ? " · " + positions[key] : "") }
  })
}

function sortedSpaces(spaces, monitors, currentMonitor, currentId) {
  var order = monitors.map(function(monitor) { return monitor.name })
  function rank(name) {
    if (name && name === currentMonitor) return -1
    var index = order.indexOf(name)
    return index >= 0 ? index : order.length
  }
  return spaces.slice().sort(function(a, b) {
    return rank(a.monitor) - rank(b.monitor) || Number(b.id === currentId) - Number(a.id === currentId)
      || Number(b.active) - Number(a.active) || a.id - b.id
  })
}

function rows(windows, model, currentId) {
  var spaces = model.list.slice().sort(function(a, b) { return a.id - b.id })
  return groupedWindowRows(windows, spaces, currentId)
}

function groupedWindowRows(windows, spaces, currentId) {
  var byId = Object.create(null), unassigned = [], result = []
  windows.forEach(function(window) {
    var id = windowWorkspace(window)
    if (!regularId(id)) { unassigned.push(window); return }
    if (!byId[id]) byId[id] = []
    byId[id].push(window)
  })
  spaces.forEach(function(space) {
    var group = byId[space.id]
    if (!group) return
    result.push({ kind: "workspace", space: space, current: space.id === currentId })
    result = result.concat(windowRows(group))
  })
  if (unassigned.length) {
    result.push({ kind: "unknown" })
    result = result.concat(windowRows(unassigned))
  }
  return result
}

function destinations(model, monitors, currentMonitor, currentId, source) {
  if (!canMove(source)) return []
  var spaces = model.list.filter(function(space) { return space.present && space.id !== source.workspaceId })
  var result = [], monitor = null
  sortedSpaces(spaces, monitors, currentMonitor, currentId).forEach(function(space) {
    if (space.monitor !== monitor) {
      monitor = space.monitor
      result.push({ kind: "monitor", monitor: monitor })
    }
    result.push({ kind: "destination", space: space, current: space.id === currentId })
  })
  return result
}

function missionLayout(windows, model, monitors, currentMonitor, currentId) {
  // The tab strip follows compositor IDs, regardless of focus or monitor.
  // In each Omarchy block the displayed slot 0 is its tenth workspace.
  var workspaces = model.list.filter(function(space) { return space.present })
    .sort(function(a, b) { return a.id - b.id })
  var spaces = sortedSpaces(model.list, monitors, currentMonitor, currentId)
  var cards = groupedWindowRows(windows, spaces, currentId).filter(function(row) {
    return row.kind === "window"
  }).map(function(row) {
    return { window: row.window, title: row.title, space: model.byId[windowWorkspace(row.window)] || null }
  })
  var currentCards = [], otherCards = []
  cards.forEach(function(card) {
    (card.space && card.space.id === currentId ? currentCards : otherCards).push(card)
  })
  return { workspaces: workspaces, currentCards: currentCards, otherCards: otherCards }
}

function missionGrid(count, width, height, scale) {
  var desired = count < 4 ? count : count === 4 ? 2 : count < 9 ? 3 : 4
  var columns = Math.max(1, Math.min(desired, Math.floor(width / (240 * scale))))
  var limit = (count === 1 ? 920 : columns === 2 ? 690 : 550) * scale
  var cellWidth = Math.max(0, Math.floor(Math.min(limit, width / columns)))
  var rows = Math.ceil(count / columns)
  var room = height / Math.max(1, Math.min(rows, 2))
  var cellHeight = Math.floor(Math.min(cellWidth * 0.64, Math.max(150 * scale, room)))
  return { columns: columns, cellWidth: cellWidth, cellHeight: cellHeight,
    width: columns * cellWidth, height: Math.max(0, Math.min(height, rows * cellHeight)) }
}

if (typeof module !== "undefined") {
  module.exports = { regularId: regularId, slot: slot, address: address, canMove: canMove,
    canDrop: canDrop, moveExpression: moveExpression, catalog: catalog, rows: rows,
    destinations: destinations, missionLayout: missionLayout, missionGrid: missionGrid }
}
