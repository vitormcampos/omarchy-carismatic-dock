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

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.appsChanged() }
  }
}
