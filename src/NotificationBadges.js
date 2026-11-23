// The Omarchy store is read-only here. Keep only identity and arrival time;
// notification text, images, and actions do not belong in the dock.
function arrivals(raw) {
  if (typeof raw !== "string" || raw.length > 2 * 1024 * 1024) return []
  var rows
  try { rows = JSON.parse(raw) } catch (e) { return [] }
  if (!Array.isArray(rows)) return []
  return rows.slice(0, 100).filter(function(row) {
    return row && typeof row.key === "string" && /^[A-Za-z0-9_-]{1,120}$/.test(row.key)
      && typeof row.ts === "number" && isFinite(row.ts) && row.ts > 0
  }).map(function(row) {
    return { key: row.key, ts: row.ts * 1000, app: identity(row.app), icon: identity(row.appIcon) }
  })
}

function identity(value) {
  return typeof value === "string" && value.length <= 256 ? value.trim().toLowerCase() : ""
}

function desktopMatch(ids, value) {
  return ids[value] || ids[value.replace(/\.desktop$/, "")] || ""
}

function appIndex(entries) {
  var ids = Object.create(null), names = Object.create(null)
  function add(map, key, id) {
    if (!key) return
    map[key] = map[key] === undefined || map[key] === id ? id : ""
  }
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (entry && entry.id && !entry.noDisplay) {
      add(ids, identity(entry.id), entry.id)
      add(names, identity(entry.name), entry.id)
    }
  }
  return { ids: ids, names: names }
}

function appFor(row, index) {
  // The persisted format has no separate desktop-entry field. An icon can
  // stand in for one only when it exactly matches an installed desktop ID.
  return desktopMatch(index.ids, row.app) || index.names[row.app]
    || desktopMatch(index.ids, row.icon)
}

function session(startedAt) {
  return { startedAt: startedAt, focused: "", focusThrough: Object.create(null),
    seen: Object.create(null), recent: [], counts: Object.create(null) }
}

function focus(state, id, now) {
  if (state.focused === id) return false
  // A store update can arrive after the window loses focus. Remember the end
  // of that focus interval so it doesn't put a stale badge back on the icon.
  if (state.focused) state.focusThrough[state.focused] = now
  state.focused = id
  if (!id) return false
  state.focusThrough[id] = now
  if (!state.counts[id]) return false
  delete state.counts[id]
  return true
}

function ingest(state, raw, index, now) {
  var changed = false
  var rows = arrivals(raw)
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (state.seen[row.key] || row.ts > now + 1000) continue
    state.seen[row.key] = true
    state.recent.push(row.key)
    if (state.recent.length > 4096) delete state.seen[state.recent.shift()]
    // A replacement or a row moving from live to history keeps the same key.
    // Seed old keys too, but never turn the pre-existing history into badges.
    if (row.ts <= state.startedAt) continue
    var id = appFor(row, index)
    if (!id || id === state.focused || row.ts <= (state.focusThrough[id] || 0)) continue
    state.counts[id] = (state.counts[id] || 0) + 1
    changed = true
  }
  return changed
}

if (typeof module !== "undefined") {
  module.exports = { arrivals: arrivals, appIndex: appIndex, appFor: appFor,
    session: session, focus: focus, ingest: ingest }
}
