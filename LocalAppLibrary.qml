import QtQuick
import Quickshell
import qs.Commons
import "AppSearch.js" as AppSearch

// Local catalog backed by the system's XDG .desktop entries. Service plugins
// do not receive the shell's menu-only appLibrary capability.
Item {
  id: root

  signal appsChanged()

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
    return Quickshell.iconPath(value || "application-x-executable", true)
  }

  function refreshIcons() {
    // DesktopEntries monitors the application directories automatically.
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
    function onValuesChanged() { root.appsChanged() }
  }
}
