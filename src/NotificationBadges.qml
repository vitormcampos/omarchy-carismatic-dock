import QtQuick
import Quickshell
import Quickshell.Io
import "NotificationBadges.js" as Badges

Scope {
  id: root

  property string focusedAppId: ""
  readonly property string storePath: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/"
  readonly property var appIndex: Badges.appIndex(DesktopEntries.applications.values)
  property var counts: Object.create(null)
  property var badgeSession: Badges.session(Date.now())

  function syncFocus(now) {
    return root.badgeSession ? Badges.focus(root.badgeSession, root.focusedAppId, now) : false
  }

  function readSnapshot(text) {
    var now = Date.now()
    var cleared = root.syncFocus(now)
    var added = Badges.ingest(root.badgeSession, text, root.appIndex, now)
    if (cleared || added) root.publishCounts()
  }

  function publishCounts() {
    root.counts = Object.assign(Object.create(null), root.badgeSession.counts)
  }

  onFocusedAppIdChanged: {
    if (root.syncFocus(Date.now())) root.publishCounts()
  }

  // A short-lived toast can go directly to history before live.json is saved.
  // Watching both snapshots also covers notifications recorded during DND.
  FileView {
    path: root.storePath + "live.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readSnapshot(text())
    onFileChanged: reload()
  }

  FileView {
    path: root.storePath + "history.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readSnapshot(text())
    onFileChanged: reload()
  }
}
