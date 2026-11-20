import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "AppSearch.js" as AppSearch

// Local catalog backed by the system's XDG .desktop entries. Service plugins
// do not receive the shell's menu-only appLibrary capability.
Item {
  id: root

  signal appsChanged()

  // Qt can keep a stale theme cache after an installation. Direct file URLs
  // let both the drawer and dock load new icons without restarting the shell.
  property var iconIndex: Object.create(null)
  property var pendingIconIndex: Object.create(null)

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function sortedEntries(query) {
    return AppSearch.sortedEntries(DesktopEntries.applications.values || [], query)
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = Quickshell.iconPath(value || "application-x-executable", true)
    var found = root.iconIndex[value]
    if (themed) return themed
    if (found) return Util.fileUrl(found)
    return Quickshell.iconPath("application-x-executable", true)
  }

  function refreshIcons() {
    iconIndexDebounce.restart()
  }

  function iconIndexScanCommand() {
    // Use arrays and a non-login shell: support spaces in XDG paths without
    // sourcing profiles that might retrigger the desktop-entry watcher.
    return [
      'bases=("$HOME/.icons" "${XDG_DATA_HOME:-$HOME/.local/share}/icons");',
      'IFS=: read -r -a dataDirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}";',
      'for d in "${dataDirs[@]}"; do [[ -n "$d" ]] && bases+=("$d/icons"); done;',
      '{ for base in "${bases[@]}"; do',
      '[[ -d "$base" ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) \\( -name "*.svg" -o -name "*.png" -o -name "*.xpm" \\) 2>/dev/null;',
      'done;',
      'if [[ -d /usr/share/pixmaps ]]; then find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" -o -name "*.xpm" \\) 2>/dev/null; fi;',
      '} | awk \'/\\.svg$/ { print; next } { other[++n] = $0 } END { for (i = 1; i <= n; i++) print other[i] }\''
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "")
    if (value.charAt(0) !== "/") return
    var file = value.slice(value.lastIndexOf("/") + 1)
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name && !Object.prototype.hasOwnProperty.call(root.pendingIconIndex, name))
      root.pendingIconIndex[name] = value
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    onStarted: root.pendingIconIndex = Object.create(null)
    stdout: SplitParser {
      onRead: function(line) { root.indexIconLine(line) }
    }
    onExited: function(exitCode) {
      // Swap the map so existing Image bindings are reevaluated as well.
      if (exitCode === 0) root.iconIndex = root.pendingIconIndex
    }
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: {
      // Do not lose a change that arrived while a scan was still running.
      if (iconIndexScan.running) restart()
      else iconIndexScan.running = true
    }
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    var entry = DesktopEntries.byId(id)
    if (entry && entry.runInTerminal) {
      var command = (entry.command || []).filter(function(word) {
        return !/^%[a-zA-Z]$/.test(String(word))
      })
      if (command.length > 0) {
        Util.execDetached("omarchy-launch-tui " + command.map(function(word) { return Util.shellQuote(word) }).join(" "))
        return
      }
    }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function quickActions(entry) {
    return Array.from(entry && entry.actions || []).filter(function(action) {
      return action && action.id && action.name && action.command && action.command.length > 0
    })
  }

  function launchAction(entry, action) {
    // UWSM resolves the action through the desktop entry, including its
    // working directory, field codes and terminal preference.
    Quickshell.execDetached(["uwsm-app", "--", entry.id + ".desktop:" + action.id])
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached("omarchy-remove-launcher-entry " + Util.shellQuote(id) + " " + Util.shellQuote(String(name || id)))
  }

  // Open one path with an app that declares a file field code in its Exec line.
  // Field codes are substituted here rather than through gtk-launch, which
  // cannot pass arguments, and the result still runs inside the uwsm scope.
  function launchWithFile(desktopId, path, name) {
    var id = String(desktopId || "")
    var file = String(path || "")
    if (!id || !file) return false
    var entry = DesktopEntries.byId(id)
    if (!entry) return false
    var words = (entry.command || []).map(String)
    var takesFile = words.some(function(word) { return /%[fFuU]/.test(word) })
    if (!takesFile) {
      Util.execDetached("notify-send 'Carismatic Dock' " + Util.shellQuote(String(name || id) + " cannot open files"))
      return false
    }
    var uri = "file://" + file.split("/").map(encodeURIComponent).join("/")
    // Field codes may be standalone tokens or embedded in one, so expand each
    // word in place. Codes this launcher cannot honour (%i, %c, %k, ...) drop
    // out, as do words that become empty.
    function expand(word) {
      var out = ""
      var last = 0
      var re = /%%|%[fFuU]|%[a-zA-Z]/g
      var match
      while ((match = re.exec(word)) !== null) {
        out += word.slice(last, match.index)
        last = match.index + match[0].length
        if (match[0] === "%%") out += "%"
        else if (/^%[fF]$/.test(match[0])) out += file
        else if (/^%[uU]$/.test(match[0])) out += uri
      }
      return out + word.slice(last)
    }
    var args = []
    for (var i = 0; i < words.length; i++) {
      var word = expand(words[i])
      if (word !== "") args.push(word)
    }
    if (args.length === 0) return false
    var quoted = args.map(function(word) { return Util.shellQuote(word) }).join(" ")
    if (entry.runInTerminal) Util.execDetached("omarchy-launch-tui " + quoted)
    else Util.execDetached("uwsm-app -- " + quoted)
    return true
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.refreshIcons()
      root.appsChanged()
    }
  }

  Component.onCompleted: root.refreshIcons()
}
