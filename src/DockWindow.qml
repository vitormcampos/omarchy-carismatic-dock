import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel
import "WorkspaceModel.js" as WorkspaceModel

// One screen's dock. It stays mapped on regular workspaces and hides behind
// fullscreen windows. While hidden the mask is empty and clicks fall through.
PanelWindow {
  id: window
  // Right-to-left languages read this window mirrored.
  Binding { target: window.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
  Binding { target: window.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }


  property var dock: null

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string position: dock ? dock.position : "bottom"
  readonly property bool vertical: dock ? dock.vertical : false
  // Track the monitor model as well as the Qt screen. monitorFor(screen)
  // alone does not make the binding depend on an IPC monitor replacement.
  readonly property var monitor: {
    var name = screen ? screen.name : ""
    if (!name || name === "FALLBACK") return null
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].name === name) return monitors[i]
    }
    return null
  }
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1
  // A separate view per monitor: every regular workspace's apps appear, but
  // the current workspace determines which windows take priority on click.
  // Omarchy's origin tag associates minimized windows with their workspace.
  readonly property var workspaceItems: {
    if (!dock) return []
    var pinned = dock.pinnedKeys.filter(function(key) { return !!DesktopEntries.byId(key) })
    var windows = []
    dock.items.forEach(function(item) {
      item.windows.forEach(function(appWindow) {
        if (DockModel.effectiveWorkspaceId(appWindow) >= 1)
          windows.push(appWindow)
      })
    })
    return DockModel.groupItems(DockModel.orderItems(DockModel.buildItems(pinned, windows).concat(dock.folders), dock.order))
  }
  readonly property var dividerIndexes: DockModel.dividersBefore(workspaceItems)
  readonly property real dividerMargin: 5 * layoutScale
  readonly property real dividerThickness: Math.max(1, Style.normalBorderWidth) * layoutScale
  readonly property real dividerSpace: baseDividerSpace * layoutScale

  function slotStart(index) {
    var gaps = 0
    for (var i = 0; i < dividerIndexes.length; i++)
      if (dividerIndexes[i] <= index) gaps++
    return dockPadding + (index + 1 + (window.showWorkspaceButton ? 1 : 0)) * slotSize + gaps * dividerSpace
  }

  function draggedIndex(index, offset) {
    var at = slotStart(index) + offset
    var target = index
    var distance = Infinity
    for (var i = 0; i < workspaceItems.length; i++) {
      var delta = Math.abs(at - slotStart(i))
      if (delta < distance) { distance = delta; target = i }
    }
    var destination = DockModel.moveTarget(workspaceItems, index, target)
    return destination ? destination.index : index
  }

  function constrainedDragOffset(index, offset) {
    var first = DockModel.moveTarget(workspaceItems, index, 0)
    var last = DockModel.moveTarget(workspaceItems, index, workspaceItems.length - 1)
    if (!first || !last) return 0
    return Math.max(slotStart(first.index) - slotStart(index),
      Math.min(slotStart(last.index) - slotStart(index), offset))
  }
  readonly property var workspaceItemsByKey: {
    var result = {}
    for (var i = 0; i < workspaceItems.length; i++) result[workspaceItems[i].key] = workspaceItems[i]
    return result
  }
  function shownKeys() {
    return workspaceItems.map(function(item) { return item.key })
  }

  ListModel { id: workspaceItemModel }
  onWorkspaceItemsChanged: syncWorkspaceItems()
  function syncWorkspaceItems() {
    var keys = window.shownKeys()
    for (var i = 0; i < keys.length; i++) {
      if (i < workspaceItemModel.count && workspaceItemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < workspaceItemModel.count; j++) {
        if (workspaceItemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) workspaceItemModel.move(found, i, 1)
      else workspaceItemModel.insert(i, { key: keys[i] })
    }
    if (workspaceItemModel.count > keys.length)
      workspaceItemModel.remove(keys.length, workspaceItemModel.count - keys.length)
  }
  // The most fullscreen window on the workspace, as Hyprland counts it: 1 is
  // maximized, and 2 or 3 fullscreen.
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && workspaceId >= 1 && fullscreenMode < 2
  // Evaluate the dock's resting position, not its tucked position: otherwise
  // hiding it would remove the overlap and immediately show it again.
  function restingBounds() {
    var origin = window.origin()
    var monitorIpc = monitor && monitor.lastIpcObject ? monitor.lastIpcObject : ({})
    var x = position === "left" ? gap : position === "right" ? width - body.width - gap
      : Math.round((width - body.width) / 2)
    var y = position === "top" ? gap : position === "bottom" ? height - body.height - gap
      : Math.round((height - body.height) / 2)
    return { x: (monitorIpc.x || 0) + origin.x + x,
      y: (monitorIpc.y || 0) + origin.y + y, width: body.width, height: body.height }
  }

  readonly property bool hasFloatingWindows: {
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var top = toplevels[i]
      var ipc = top.lastIpcObject
      if (top.workspace && top.workspace.id === workspaceId && ipc && ipc.floating
          && !ipc.hidden && ipc.mapped !== false) return true
    }
    return false
  }
  readonly property bool smartObstructed: {
    if (!dock || workspaceId < 1) return false
    var bounds = window.restingBounds()
    var tiledMode = dock.modes[workspaceId] !== "floating"
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var top = toplevels[i]
      var ipc = top.lastIpcObject
      if (!top.workspace || top.workspace.id !== workspaceId || !ipc
          || ipc.hidden || ipc.mapped === false) continue
      if (tiledMode && ipc.floating === false) return true
      if (DockModel.overlapsDock(ipc, bounds)) return true
    }
    return false
  }

  readonly property bool alwaysVisible: !!dock && dock.alwaysVisible
  // Outside always-visible mode, an obstruction or the auto-hide preference
  // tucks the dock until the pointer reaches its edge.
  readonly property bool autohide: !!dock && !alwaysVisible
    && (dock.autohide || fullscreenMode === 1 || smartObstructed)
  property bool revealed: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu || pickerKey !== ""
    || stackItem !== null
  readonly property bool tucked: autohide
    && !(revealed || menuOpen || dragging || insertIndex >= 0 || folderDrop.active)
  readonly property bool contentShown: shown && !tucked

  readonly property int gap: Style.spacing.xs
  readonly property real dockPadding: Style.spacing.xs * layoutScale
  readonly property string backgroundMode: dock && dock.shell && dock.shell.barConfig
    ? (dock.shell.barConfig.background || (dock.shell.barConfig.transparent === true ? "none" : "opaque"))
    : "opaque"
  readonly property color themeBackground: Commons.Color.bar.background
  readonly property color glassBackground: Qt.rgba(themeBackground.r, themeBackground.g,
    themeBackground.b, Math.min(themeBackground.a, 0.35))
  readonly property int baseIconSize: Math.round(44 * Style.fontScale)
  // Each app has a square slot with its icon in the middle, and the slots run
  // straight to the edge of the dock.
  // Leave room below the full 15% hover expansion for the running indicator,
  // including when top-edge scaling grows the icon entirely downward.
  readonly property int baseIconInset: Math.max(Style.spacing.md, Math.ceil(baseIconSize * 0.15) + Style.space(5))
  readonly property int baseSlotSize: Math.max(baseIconSize + baseIconInset * 2, 56)
  readonly property int baseDividerSpace: 10 + Math.max(1, Style.normalBorderWidth)
  readonly property bool reserveDropSlot: insertIndex >= 0
    || (folderDrop.active && folderDrop.hasLocalUrl && folderDrop.directory)
  readonly property bool showWorkspaceButton: !!dock && dock.showWorkspaceButton === true
  readonly property int layoutSlotCount: appRepeater.count + 1 + (reserveDropSlot ? 1 : 0) + (showWorkspaceButton ? 1 : 0)
  readonly property real naturalLength: layoutSlotCount * baseSlotSize
    + dividerIndexes.length * baseDividerSpace + Style.spacing.xs * 2
  // Opposite anchors make this dimension the compositor's usable logical
  // monitor length, already excluding space reserved by the system bar.
  // It does not depend on the dock's thickness, avoiding a sizing feedback loop.
  readonly property real availableLength: Math.max(1, (vertical ? height : width) - gap * 2)
  readonly property real layoutScale: DockModel.fitScale(availableLength, naturalLength)
  // Fractional metrics are intentional: rounding every slot would accumulate
  // overflow, and a minimum pixel size would prevent very large docks fitting.
  readonly property real iconSize: baseIconSize * layoutScale
  readonly property real slotSize: baseSlotSize * layoutScale
  readonly property real iconInset: (slotSize - iconSize) / 2
  readonly property real runningIndicatorHeight: Math.max(1, Style.space(3)) * layoutScale
  // Clear the artwork's maximum downward hover expansion in every orientation.
  readonly property real runningIndicatorY: iconInset + iconSize
    + Math.max(Style.space(3),
      Math.ceil(baseIconSize * (position === "top" ? 0.15 : vertical ? 0.075 : 0)) + Style.space(2)) * layoutScale
  readonly property real appsIconSize: 56 * layoutScale
  // Keep enough room for the largest menu (two actions and eight entries).
  // Resizing the layer surface on every folder open/close can flash the dock.
  // The input mask still includes only the dock and the currently visible menu.
  readonly property int popupRows: 10
  readonly property int popupRoom: Style.spacing.popupRowHeight * popupRows + Style.spacing.sm * 2 + Style.normalBorderWidth * 2 + gap * 2
  // Icons pop away from the screen edge.
  readonly property int popOrigin: position === "top" ? Item.Top
    : position === "left" ? Item.Left
    : position === "right" ? Item.Right
    : Item.Bottom

  // The app being dragged along the dock, how far the pointer has taken it,
  // and the slot it would land in.
  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0
  // Off while a drop resets the slots: they snap to where the reorder puts
  // them rather than sliding back from where they stepped aside. Set before
  // the drag state changes, so the slots never see the reset animated.
  property bool animateShifts: true
  // After a drop the slots have moved under a pointer that has not, so what
  // they think is hovered is stale until it moves again.
  property bool hoverStale: false
  property point dropPoint
  // Where an app dragged in from the app grid would land, or -1.
  property int insertIndex: -1
  // The item under a file dragged from a file manager, or null.
  readonly property var fileTargetItem: folderDrop.active && folderDrop.checked && !folderDrop.directory
    ? window.slotItemAt(folderDrop.lastPoint.x - body.x, folderDrop.lastPoint.y - body.y) : null

  // Where this window sits on its screen, which a point from the app grid's
  // fullscreen surface is given in: against its edge, clear of the space
  // other surfaces such as the bar reserve. Hyprland lists that space as
  // left, top, right, bottom.
  function origin() {
    var reserved = monitor && monitor.lastIpcObject && monitor.lastIpcObject.reserved ? monitor.lastIpcObject.reserved : [0, 0, 0, 0]
    var left = reserved[0] || 0, top = reserved[1] || 0, right = reserved[2] || 0, bottom = reserved[3] || 0
    // The monitor reports our own reservation too. The dock sits inside it.
    if (window.position === "left") left = Math.max(0, left - window.exclusiveZone)
    if (window.position === "top") top = Math.max(0, top - window.exclusiveZone)
    if (window.position === "right") right = Math.max(0, right - window.exclusiveZone)
    if (window.position === "bottom") bottom = Math.max(0, bottom - window.exclusiveZone)
    var x = window.position === "right" ? screen.width - right - window.width : left
    var y = window.position === "bottom" ? screen.height - bottom - window.height : top
    return Qt.point(x, y)
  }

  // An app from the app grid lands where the pointer is, once it is over the
  // dock or close to it on the inward side.
  function moveExternalDrag(screenX, screenY) {
    var at = window.origin()
    var point = Qt.point(screenX - at.x - body.x, screenY - at.y - body.y)
    var reach = window.slotSize
    var along = window.vertical ? point.y : point.x
    var across = window.vertical ? point.x : point.y
    var length = window.vertical ? body.height : body.width
    var depth = window.vertical ? body.width : body.height
    var near = along >= -window.slotSize && along <= length + window.slotSize && across >= -reach && across <= depth + reach
    if (window.shown && window.autohide && near) window.revealed = true
    var pinCount = window.workspaceItems.filter(function(item) { return DockModel.itemGroup(item) === 0 }).length
    window.insertIndex = window.shown && near ? Math.min(pinCount, window.slotIndexAt(point)) : -1
  }

  function dropExternalDrag(screenX, screenY, key) {
    window.moveExternalDrag(screenX, screenY)
    window.settleShifts()
    if (window.insertIndex >= 0 && key && window.dock) window.dock.pinAt(key, window.insertIndex, window.shownKeys())
    window.endExternalDrag()
  }

  function endExternalDrag() {
    window.insertIndex = -1
    if (window.autohide) hideTimer.restart()
  }

  // The slot a point along the dock falls before, counting from the first app.
  function slotIndexAt(point) {
    var along = window.vertical ? point.y : point.x
    var count = workspaceItemModel.count
    for (var i = 0; i < count; i++)
      if (along < window.slotStart(i) + window.slotSize / 2) return i
    return count
  }

  // The dock item under a point in body coordinates, or null. The Apps and
  // Mission Control buttons are not file drop targets.
  function slotItemAt(x, y) {
    var along = window.vertical ? y : x
    var across = window.vertical ? x : y
    var depth = window.vertical ? body.width : body.height
    if (across < window.dockPadding || across >= depth - window.dockPadding) return null
    // Insertion switches slots at their centers; file targets instead own
    // their full rectangle, excluding the gaps occupied by dividers.
    for (var i = 0; i < window.workspaceItems.length; i++) {
      var start = window.slotStart(i)
      if (along >= start && along < start + window.slotSize)
        return window.workspaceItems[i].builtin === "trash" ? null : window.workspaceItems[i]
    }
    return null
  }
  property var menuItem: null
  property string pickerKey: ""
  property string moveAddress: ""
  property Item menuSlot: null
  // The apps button's menu: where the dock sits and whether it hides.
  property bool settingsMenu: false
  // A folder's contents, opened as a stack above its icon.
  property var stackItem: null
  property var stackEntries: []
  property bool stackUnavailable: false
  property bool stackLoading: false

  onWorkspaceIdChanged: {
    closeMenu()
    if (dragging) endDrag()
    if (dock) dock.readMode(workspaceId)
  }
  onShownChanged: {
    if (shown) return
    closeMenu()
    window.revealed = false
  }
  Component.onCompleted: {
    if (dock) dock.readMode(workspaceId)
    syncWorkspaceItems()
  }

  function openMenu(item, slot) {
    if (item && item.type === "folder" && item.builtin !== "trash") {
      window.openStack(item, slot)
      return
    }
    window.closeWindowLists()
    window.settingsMenu = false
    window.closeStack()
    window.menuItem = item
    window.menuSlot = slot
  }

  function openSettingsMenu(slot) {
    window.menuItem = null
    window.closeWindowLists()
    window.settingsMenu = true
    window.closeStack()
    window.menuSlot = slot
  }

  function openWindowPicker(item, slot) {
    if (!item) return
    window.menuItem = null
    window.settingsMenu = false
    window.closeWindowLists()
    window.pickerKey = item.key
    window.closeStack()
    window.menuSlot = slot
  }

  function openWorkspaceOverview() {
    window.closeMenu()
    if (window.dock) window.dock.openMissionControl(window.screen)
  }

  function closeWindowLists() {
    window.pickerKey = ""
    window.moveAddress = ""
  }

  function workspaceRowLabel(row, showMonitor) {
    if (row.kind === "monitor") return row.monitor || strings.t("dock.workspaceUnknownMonitor")
    if (row.kind === "unknown") return strings.t("dock.workspaceUnknown")
    if (row.kind === "window") {
      var title = row.title || strings.t("dock.workspaceUntitled")
      return row.window.minimized ? strings.t("dock.workspaceMinimized").arg(title) : title
    }
    var space = row.space
    var number = Commons.I18n.formatNumber(space.fullId ? space.id : WorkspaceModel.slot(space.id))
    var label = strings.t("dock.workspaceNumber").arg(space.fullId ? "#" + number : number)
    if (showMonitor && space.monitor) label = strings.t("dock.workspaceOnMonitor").arg(label).arg(space.monitor)
    if (row.current) label = strings.t("dock.workspaceCurrent").arg(label)
    else if (space.active) label = strings.t("dock.workspaceActive").arg(label)
    return label
  }

  function settleShifts() {
    window.animateShifts = false
    Qt.callLater(function() { window.animateShifts = true })
  }

  function endDrag() {
    window.settleShifts()
    window.hoverStale = true
    window.dragIndex = -1
    window.dropIndex = -1
    window.dragOffset = 0
  }

  function closeStack() {
    window.stackItem = null
    window.stackEntries = []
    window.stackUnavailable = false
    window.stackLoading = false
    stackProc.running = false
  }

  function closeMenu() {
    window.menuItem = null
    window.closeWindowLists()
    window.settingsMenu = false
    window.menuSlot = null
    window.closeStack()
    if (window.autohide) hideTimer.restart()
  }

  // The folder stack lists its contents through the same helper the dock uses
  // to persist shortcuts, so a missing folder is reported instead of looking
  // empty.
  function openStack(item, slot) {
    if (!item || item.type !== "folder" || item.builtin === "trash" || !window.dock) return
    window.menuItem = item
    window.closeWindowLists()
    window.settingsMenu = false
    window.stackItem = item
    window.menuSlot = slot
    window.stackEntries = []
    window.stackUnavailable = false
    window.stackLoading = true
    stackProc.running = false
    stackProc.command = [window.dock.folderScriptPath(), "list", item.path]
    stackProc.running = true
  }

  Process {
    id: stackProc
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = text.trim()
        if (raw === "null") {
          window.stackEntries = []
          window.stackUnavailable = true
          return
        }
        try {
          var parsed = raw === "" ? [] : JSON.parse(raw)
          window.stackEntries = Array.isArray(parsed) ? parsed : []
        } catch (error) {
          window.stackEntries = []
          window.stackUnavailable = true
        }
      }
    }
    onExited: function(code) {
      if (!window.stackItem) return
      window.stackLoading = false
      if (code !== 0) window.stackUnavailable = true
    }
  }

  // Icons for stack rows come from the file extension; a GIO lookup per item
  // would cost a process per row for little gain in a short popup.
  function stackIcon(entry) {
    if (!entry) return ""
    if (entry.dir) return window.dock ? window.dock.appLibrary.iconSource("folder") : Quickshell.iconPath("folder", true)
    return window.dock ? window.dock.appLibrary.iconSource(window.stackMimeIcon(entry.name)) : Quickshell.iconPath(window.stackMimeIcon(entry.name), true)
  }

  function stackMimeIcon(name) {
    var text = String(name || "")
    var dot = text.lastIndexOf(".")
    var ext = dot > 0 ? text.slice(dot + 1).toLowerCase() : ""
    var icons = {
      txt: "text-x-generic", md: "text-x-generic", log: "text-x-generic", json: "text-x-generic",
      pdf: "application-pdf", html: "text-html",
      png: "image-x-generic", jpg: "image-x-generic", jpeg: "image-x-generic", gif: "image-x-generic",
      webp: "image-x-generic", svg: "image-x-generic", bmp: "image-x-generic",
      mp4: "video-x-generic", mkv: "video-x-generic", webm: "video-x-generic", mov: "video-x-generic",
      mp3: "audio-x-generic", flac: "audio-x-generic", wav: "audio-x-generic", ogg: "audio-x-generic",
      zip: "package-x-generic", tar: "package-x-generic", gz: "package-x-generic",
      "7z": "package-x-generic", rar: "package-x-generic", deb: "package-x-generic", pkg: "package-x-generic",
      sh: "text-x-script", py: "text-x-script", js: "text-x-script", ts: "text-x-script",
      desktop: "application-x-desktop"
    }
    return icons[ext] || "text-x-generic"
  }

  // Places the menu inward of the dock, centered on a slot.
  function popupX(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, slot.width / 2, 0).x
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, 0, slot.height / 2).y
    if (window.position === "top") return body.y + body.height + window.gap
    if (window.position === "bottom") return body.y - window.gap - popup.height
    return Math.max(window.gap, Math.min(window.height - popup.height - window.gap, center - popup.height / 2))
  }

  visible: !!window.monitor && !remapGuard.remapping && !displayRemapTimer.running
  color: "transparent"
  surfaceFormat.opaque: false
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Reserve the strip occupied by the icons. The rest of the surface is
  // available for popups and should not affect the workspace layout.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: window.alwaysVisible && window.shown
    ? Math.ceil(window.gap + window.slotSize + window.dockPadding * 2) : 0

  anchors {
    top: window.position !== "bottom"
    bottom: window.position !== "top"
    left: window.position !== "right"
    right: window.position !== "left"
  }

  implicitWidth: window.vertical ? window.gap + window.slotSize + window.dockPadding * 2 + window.popupRoom : 0
  implicitHeight: window.vertical ? 0 : window.gap + window.slotSize + window.dockPadding * 2 + window.popupRoom

  mask: Region {
    item: window.contentShown ? body : null

    Region { item: window.shown && window.autohide ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
  }

  onAutohideChanged: window.revealed = window.autohide && (bodyHover.hovered || window.menuOpen || window.dragging)

  // Hyprland's toplevel list updates on open/close/workspace changes, not on
  // every frame of a floating drag or resize. Poll only while such windows
  // exist on this screen so overlap follows their final geometry.
  Timer {
    interval: 500
    repeat: true
    running: window.shown && !window.alwaysVisible && window.hasFloatingWindows
    onTriggered: Hyprland.refreshToplevels()
  }

  Timer {
    id: hideTimer
    // Long enough to cross a gap between the edge and the icons, no longer.
    interval: 150
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.menuOpen && !window.dragging
          && !folderDrop.active) window.revealed = false
    }
  }

  // The strip along the screen edge that brings an auto-hidden dock back.
  Item {
    id: edgeTrigger

    readonly property int depth: window.gap + Style.spacing.xxs

    x: window.position === "left" ? 0 : window.position === "right" ? window.width - depth : body.x
    y: window.position === "top" ? 0 : window.position === "bottom" ? window.height - depth : body.y
    width: window.vertical ? depth : body.width
    height: window.vertical ? body.height : depth

    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }
  }

  ScreenMoveRemap {
    id: remapGuard
    window: window
  }

  function remapAfterDisplayChange() {
    window.closeMenu()
    if (window.dragging) window.endDrag()
    window.revealed = false
    displayRemapTimer.restart()
  }

  // Keep the dock unmapped long enough for layer-shell to process the unmap.
  Timer {
    id: displayRemapTimer
    interval: 75
    onTriggered: window.revealed = window.autohide && (bodyHover.hovered || edgeHover.hovered)
  }

  HyprlandFocusGrab {
    active: window.menuOpen
    windows: [window]
    onCleared: window.closeMenu()
  }

  Item {
    id: body

    // The strip keeps its order in every language, like the bar: drags and
    // drops reckon slots along x from the first app. Only the menu mirrors.
    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    width: slots.implicitWidth + window.dockPadding * 2
    height: slots.implicitHeight + window.dockPadding * 2
    // How far the dock is tucked past its edge. Auto-hide slides it, but only
    // while the dock is on screen: arriving on a regular workspace shows it
    // where it belongs at once.
    property real tuck: window.tucked ? window.slotSize + window.dockPadding * 2 + window.gap : 0

    // Tucking away is quicker than coming back. A gentler curve than
    // Style.easeOut, which crosses the short slide in a frame or two.
    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 120 : 180)
        easing.type: Easing.OutCubic
      }
    }

    x: window.position === "left" ? window.gap - tuck
      : window.position === "right" ? window.width - width - window.gap + tuck
      : Math.round((window.width - width) / 2)
    y: window.position === "top" ? window.gap - tuck
      : window.position === "bottom" ? window.height - height - window.gap + tuck
      : Math.round((window.height - height) / 2)
    // Fullscreen or special workspaces hide the dock at once. Hidden by opacity rather than
    // visibility, so the icons keep their textures and are drawn on the first
    // frame back instead of being uploaded again.
    opacity: window.shown ? 1 : 0

    // One theme-matched surface for the whole dock, growing with its icons.
    // The bar's glass mode uses the same color with alpha capped at 0.35;
    // Hyprland provides blur only behind the painted part of this layer.
    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius * window.layoutScale
      color: window.backgroundMode === "none" ? "transparent"
        : window.backgroundMode === "glassy" ? window.glassBackground : window.themeBackground

      Behavior on color {
        ColorAnimation { duration: Style.duration(250); easing.type: Easing.OutCubic }
      }
    }

    HoverHandler {
      id: bodyHover
      onHoveredChanged: if (!hovered && window.autohide) hideTimer.restart()
      // Only a real move clears it: the release itself reports the pointer too.
      onPointChanged: {
        if (!window.hoverStale || window.dragging) return
        var at = point.position
        if (Math.hypot(at.x - window.dropPoint.x, at.y - window.dropPoint.y) > Style.space(4)) window.hoverStale = false
      }
    }

    Grid {
      id: slots
      anchors.centerIn: parent
      // The extra column holds the drop spacer, which only takes a slot while
      // a drop target is active, so the row never wraps.
      columns: window.vertical ? 1 : appRepeater.count + 2 + (window.showWorkspaceButton ? 1 : 0)

      AppsSlot {}
      MissionControlSlot { visible: window.showWorkspaceButton }

      Repeater {
        id: appRepeater
        model: workspaceItemModel

        delegate: Item {
          id: entry
          required property int index
          required property string key
          readonly property bool divided: window.dividerIndexes.indexOf(index) >= 0

          width: window.slotSize + (divided && !window.vertical ? window.dividerSpace : 0)
          height: window.slotSize + (divided && window.vertical ? window.dividerSpace : 0)

          Rectangle {
            visible: entry.divided
            x: window.dividerMargin
            y: window.vertical ? window.dividerMargin
              : Math.round((window.slotSize - height) / 2)
            width: window.vertical ? window.slotSize - window.dividerMargin * 2 : window.dividerThickness
            height: window.vertical ? window.dividerThickness : window.slotSize - window.dividerMargin * 2
            color: Commons.Color.bar.text
            opacity: 0.45
          }

          AppSlot {
            index: entry.index
            key: entry.key
            x: entry.divided && !window.vertical ? window.dividerSpace : 0
            y: entry.divided && window.vertical ? window.dividerSpace : 0
          }
        }
      }

      // The spacer that makes room for a drop. A folder from Nautilus lands at
      // the end of the shortcut group; an app from the grid opens a gap at its
      // own position (marked below). Growing by one slot keeps every icon
      // inside the dock's background instead of sliding past its ends.
      Item {
        readonly property bool folderSlot: folderDrop.active && folderDrop.hasLocalUrl
          && folderDrop.directory
        readonly property bool reserved: window.reserveDropSlot

        width: reserved ? window.slotSize : 0
        height: reserved ? window.slotSize : 0

        // Resize atomically with layoutScale. Animating a disappearing spacer
        // while the remaining slots expand would briefly exceed the monitor.

        Rectangle {
          visible: parent.folderSlot
          anchors.fill: parent
          anchors.margins: window.slotSize * 0.04
          radius: window.slotSize * 0.22
          color: "transparent"
          border.width: Math.max(1, Style.normalBorderWidth) * window.layoutScale
          border.color: Commons.Color.accent
          opacity: 0.7

          Text {
            anchors.centerIn: parent
            text: "+"
            color: Commons.Color.accent
            font.family: Style.font.menuFamily
            font.pixelSize: Math.round(window.iconSize * 0.45)
          }
        }
      }
    }

    // The slot an app dragged out of the grid will take. The gap itself is
    // opened by shifting the later slots, so this only marks it.
    Item {
      visible: window.insertIndex >= 0
      x: window.vertical ? window.dockPadding : window.slotStart(window.insertIndex)
      y: window.vertical ? window.slotStart(window.insertIndex) : window.dockPadding
      width: window.slotSize
      height: window.slotSize

      Behavior on x {
        enabled: !window.vertical
        NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
      }
      Behavior on y {
        enabled: window.vertical
        NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.fill: parent
        anchors.margins: window.slotSize * 0.04
        radius: window.slotSize * 0.22
        color: "transparent"
        border.width: Math.max(1, Style.normalBorderWidth) * window.layoutScale
        border.color: Commons.Color.accent
        opacity: 0.7

        Text {
          anchors.centerIn: parent
          text: "+"
          color: Commons.Color.accent
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(window.iconSize * 0.45)
        }
      }
    }

    // Nautilus supplies file:// URLs through Wayland drag-and-drop. The app
    // grid uses its own pointer drag, so this target only handles OS drops.
    DropArea {
      id: folderDrop
      anchors.fill: parent
      // External drags are the only ones this target sees; the app grid uses
      // its own pointer drag and never becomes a QML drag source.
      readonly property bool active: containsDrag
      property string pendingUrl: ""
      property string checkedUrl: ""
      property bool hasLocalUrl: false
      property bool checked: false
      property bool directory: false
      // Content coordinates keep a stationary pointer aligned with its target
      // when the dock moves or changes size during an external drag.
      property point lastPoint

      function localFolderUrl(event) {
        if (!event.hasUrls || event.urls.length !== 1) return ""
        var url = String(event.urls[0])
        return url.indexOf("file://") === 0 ? url : ""
      }

      function localPath(url) {
        var path = url.slice("file://".length)
        if (path.indexOf("localhost/") === 0) path = path.slice("localhost".length)
        try { return decodeURIComponent(path) } catch (error) { return "" }
      }

      // Only a single local path is any use here: folders become shortcuts,
      // files open in the app, or move into the folder, under the pointer.
      // While the path is still unchecked the drag looks acceptable, so a
      // folder does not flash the error color on entry.
      readonly property bool accepted: hasLocalUrl && (!checked || directory
        || window.fileTargetItem !== null)

      function track(drag) {
        var url = localFolderUrl(drag)
        lastPoint = folderDrop.mapToItem(window.contentItem, drag.x, drag.y)
        if (url !== pendingUrl) {
          pendingUrl = url
          checkedUrl = url
          hasLocalUrl = url !== ""
          checked = false
          directory = false
          if (url) {
            pathCheck.running = false
            pathCheck.command = ["/usr/bin/test", "-d", localPath(url)]
            pathCheck.running = true
          }
        }
        // An ignored action keeps the "not allowed" cursor while still
        // receiving moves, so the dock can show why the drop will not work.
        drag.accept(accepted ? Qt.CopyAction : Qt.IgnoreAction)
      }

      // The drag payload is only a path, so ask the filesystem whether it is a
      // directory before deciding what a release will do.
      Process {
        id: pathCheck
        onExited: function(code) {
          if (folderDrop.pendingUrl === "" || folderDrop.checkedUrl !== folderDrop.pendingUrl) return
          folderDrop.checked = true
          folderDrop.directory = code === 0
        }
      }

      onEntered: function(drag) { track(drag) }
      onPositionChanged: function(drag) { track(drag) }
      // The drop is read from the event, not from cached state, so a drag that
      // ends without an exit still registers only the URL that was checked.
      onDropped: function(drop) {
        var url = localFolderUrl(drop)
        var checkedHere = checked
        var isFolder = directory
        pathCheck.running = false
        if (!url || !window.dock) { drop.accepted = false; return }
        // An unresolved check falls back to the shortcut path, which validates
        // the folder again in the helper before writing anything.
        if (isFolder || !checkedHere) {
          drop.accept(Qt.CopyAction)
          Util.execDetached(window.dock.folderCommand() + " add-url " + Util.shellQuote(url))
          return
        }
        var item = window.slotItemAt(drop.x, drop.y)
        if (!item) {
          drop.accepted = false
          Util.execDetached("notify-send 'Carismatic Dock' 'Drop the file on an app or folder icon'")
          return
        }
        drop.accept(Qt.CopyAction)
        window.dock.openDroppedFile(item, localPath(url))
      }
    }

    // One outline for both drop sources: a file manager drag, or an app dragged
    // out of the grid. A drag that will do nothing turns it to the error color.
    Rectangle {
      anchors.fill: parent
      readonly property bool folderDragging: folderDrop.active
      visible: folderDragging || window.insertIndex >= 0
      radius: Style.cornerRadius * window.layoutScale
      color: "transparent"
      border.width: Math.max(1, Style.normalBorderWidth) * window.layoutScale
      border.color: folderDragging && !folderDrop.accepted ? Commons.Color.urgent : Commons.Color.accent
    }
  }

  component Slot: Item {
    id: slot

    // Only the dragged icon is lifted while a drag is on; none of the others
    // pop as it passes over them.
    property bool hovered: mouse.containsMouse && !window.hoverStale && !window.dragging
    property bool pressed: mouse.pressed
    property alias mouse: mouse

    width: window.slotSize
    height: window.slotSize

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    }
  }

  component MissionControlSlot: Slot {
    id: overviewSlot
    mouse.onClicked: function(event) {
      if (event.button === Qt.LeftButton) window.openWorkspaceOverview()
    }

    Row {
      id: overviewGlyph
      readonly property real glyphSize: window.iconSize * 1.25
      anchors.centerIn: parent
      spacing: glyphSize * 0.07
      scale: overviewSlot.hovered ? 1.15 : 1
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      Rectangle {
        width: overviewGlyph.glyphSize * 0.34
        height: overviewGlyph.glyphSize * 0.48
        radius: overviewGlyph.glyphSize * 0.055
        color: Commons.Color.foreground
      }
      Column {
        spacing: overviewGlyph.spacing
        Repeater {
          model: 2
          Rectangle {
            width: overviewGlyph.glyphSize * 0.24
            height: overviewGlyph.glyphSize * 0.205
            radius: overviewGlyph.glyphSize * 0.055
            color: Commons.Color.foreground
          }
        }
      }
    }

    PanelToolTip {
      id: overviewTip
      visible: overviewSlot.hovered && window.contentShown && !window.menuOpen
      text: "Mission Control"
      width: Math.min(implicitWidth, window.vertical
        ? window.popupRoom - window.gap * 2 : window.width - window.gap * 2)
      x: window.popupX(overviewSlot, overviewTip) - overviewSlot.mapToItem(window.contentItem, 0, 0).x
      y: window.popupY(overviewSlot, overviewTip) - overviewSlot.mapToItem(window.contentItem, 0, 0).y
    }
  }

  component AppsSlot: Slot {
    id: appsSlot

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openSettingsMenu(appsSlot)
        return
      }
      window.closeMenu()
      if (window.dock) window.dock.openApps()
    }

    OpticalGlyph {
      anchors.centerIn: parent
      width: window.appsIconSize
      height: window.appsIconSize
      text: "\ue900"
      fontFamily: "omarchy"
      fontSize: window.baseIconSize
      paintedSize: window.appsIconSize
      color: Commons.Color.foreground
      // The larger mark stays within its slot even when hovered.
      scale: appsSlot.hovered ? Math.min(1.15, window.slotSize / width) : 1
      transformOrigin: Item.Center

      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
  }

  component AppSlot: Slot {
    id: appSlot

    required property int index
    required property string key
    readonly property var modelData: window.workspaceItemsByKey[key] || null
    readonly property string label: {
      if (!modelData) return ""
      if (modelData.type === "folder") return modelData.name
      var entry = window.dock ? window.dock.entryFor(modelData) : null
      return String((entry && entry.name) || modelData.key)
    }
    readonly property int launchSerial: {
      var launch = window.dock ? window.dock.launches[key] : null
      return launch ? launch.serial : 0
    }
    property bool launchReady: false
    property real hopOffset: 0
    Component.onCompleted: launchReady = true
    onLaunchSerialChanged: {
      if (launchReady && launchSerial > 0 && !Style.reduceMotion && !window.dragging) launchHop.restart()
    }
    readonly property bool lifted: window.dragIndex === index
    onLiftedChanged: if (lifted) launchHop.stop()
    // A file dropped here opens in this app, or moves into this folder.
    readonly property bool fileTarget: !!window.fileTargetItem && window.fileTargetItem.key === key
    readonly property bool clickPressed: mouse.pressed && !dragged && !window.dragging
      && !!(mouse.pressedButtons & (Qt.LeftButton | Qt.MiddleButton))
    property point pressPoint
    property bool dragged: false
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property int notificationCount: window.dock && modelData && modelData.type === "app"
      ? (window.dock.notificationCounts[key] || 0) : 0

    // Slots between where the dragged app was and where it would land step
    // aside to make room; the dragged one follows the pointer. An app dragged
    // in from the grid only pushes the later slots along, so the gap opens
    // inside the dock and nothing slides out past its background.
    readonly property real shift: window.insertIndex >= 0 ? (index >= window.insertIndex ? window.slotSize : 0)
      : !window.dragging ? 0
      : lifted ? window.dragOffset
      : (window.dragIndex < index && index <= window.dropIndex) ? window.slotStart(index - 1) - window.slotStart(index)
      : (window.dropIndex <= index && index < window.dragIndex) ? window.slotStart(index + 1) - window.slotStart(index)
      : 0
    property real displayedShift: shift

    // Only while dragging: once the drop reorders the slots, they are already
    // where they were shown.
    Behavior on displayedShift {
      enabled: window.animateShifts && ((window.dragging && !appSlot.lifted) || window.insertIndex >= 0)
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    z: lifted ? 1 : 0

    // The slot, and the pointer handling in it, stays where it is; only the
    // icon moves. Reading the pointer through a slot that moves with it would
    // feed each move back into the next.
    function bodyPoint(event) {
      return appSlot.mapToItem(body, event.x, event.y)
    }

    mouse.onPressed: function(event) {
      appSlot.dragged = false
      if (event.button === Qt.LeftButton) appSlot.pressPoint = appSlot.bodyPoint(event)
    }

    mouse.onPositionChanged: function(event) {
      if (!(appSlot.mouse.pressedButtons & Qt.LeftButton)) return
      if (appSlot.modelData && appSlot.modelData.fixed) return
      var point = appSlot.bodyPoint(event)
      var delta = window.vertical ? point.y - appSlot.pressPoint.y : point.x - appSlot.pressPoint.x
      // A press that wanders is a drag in the making, not a click.
      if (Math.hypot(point.x - appSlot.pressPoint.x, point.y - appSlot.pressPoint.y) > Style.space(4)) appSlot.dragged = true
      if (!window.dragging) {
        if (Math.abs(delta) < Style.space(6)) return
        window.closeMenu()
        // The landing slot first: with the dragged slot set and no landing
        // slot yet, every slot before it would count as in between and step
        // aside for a moment.
        window.dropIndex = appSlot.index
        window.dragIndex = appSlot.index
      }
      if (!appSlot.lifted) return
      window.dragOffset = window.constrainedDragOffset(appSlot.index, delta)
      window.dropIndex = window.draggedIndex(appSlot.index, delta)
    }

    mouse.onReleased: function(event) {
      if (!appSlot.lifted) return
      window.dropPoint = appSlot.mapToItem(body, event.x, event.y)
      var from = window.dragIndex
      var to = window.dropIndex
      appSlot.dragged = true
      window.endDrag()
      window.dock.moveItem(from, to, window.shownKeys())
    }

    mouse.onCanceled: if (appSlot.lifted) window.endDrag()

    mouse.onClicked: function(event) {
      // A drag ends in a release over the app, which is not a click on it.
      if (appSlot.dragged) {
        appSlot.dragged = false
        return
      }
      if (event.button === Qt.RightButton) {
        window.openMenu(appSlot.modelData, appSlot)
        return
      }
      var folder = !!appSlot.modelData && appSlot.modelData.type === "folder"
      window.closeMenu()
      if (folder || event.button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
      else if (appSlot.windowCount > 1) window.openWindowPicker(appSlot.modelData, appSlot)
      else window.dock.activate(appSlot.modelData, window.workspaceId)
    }

    PanelToolTip {
      visible: appSlot.hovered && window.contentShown && !window.menuOpen
        && window.insertIndex < 0 && appSlot.label !== ""
      text: !appSlot.notificationCount ? appSlot.label : appSlot.label + "\n"
        + strings.tn("dock.newNotifications", appSlot.notificationCount)
          .arg(Commons.I18n.formatNumber(appSlot.notificationCount))
      width: Math.min(implicitWidth, window.vertical
        ? window.popupRoom - window.gap * 2 : window.width - window.gap * 2)
      x: window.position === "left" ? appSlot.width + window.gap
        : window.position === "right" ? -width - window.gap
        : Math.max(window.gap - body.x - appSlot.parent.x - appSlot.x,
            Math.min(window.width - window.gap - body.x - appSlot.parent.x - appSlot.x - width,
              (appSlot.width - width) / 2))
      y: window.position === "top" ? appSlot.height + window.gap
        : window.position === "bottom" ? -height - window.gap
        : Math.max(window.gap - body.y - appSlot.parent.y - appSlot.y,
            Math.min(window.height - window.gap - body.y - appSlot.parent.y - appSlot.y - height,
              (appSlot.height - height) / 2))
    }

    // Pressing confirms the click; a launch moves only the artwork, not the
    // slot or its hit target, away from the screen edge and back once.
    Image {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      sourceSize: Qt.size(Math.max(1, window.iconSize * 2), Math.max(1, window.iconSize * 2))
      source: window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      transform: Translate {
        x: window.vertical ? (window.position === "left" ? appSlot.hopOffset : -appSlot.hopOffset) : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift
          : (window.position === "top" ? appSlot.hopOffset : -appSlot.hopOffset)
      }
      scale: (appSlot.lifted || appSlot.hovered || appSlot.fileTarget ? 1.15 : 1) * (appSlot.clickPressed ? 0.93 : 1)
      transformOrigin: window.popOrigin

      Behavior on scale {
        NumberAnimation {
          duration: Style.duration(appSlot.clickPressed ? 90 : 180)
          easing.type: Easing.OutCubic
        }
      }
    }

    // Running state is independent of workspace and stays below the artwork.
    // Follow reordering, but not the icon's hover scale or launch hop.
    Rectangle {
      visible: !!appSlot.modelData && appSlot.modelData.type !== "folder" && appSlot.windowCount > 0
      x: (appSlot.width - width) / 2
      y: window.runningIndicatorY
      width: window.iconSize * 0.4
      height: window.runningIndicatorHeight
      radius: height / 2
      color: Commons.Color.foreground
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }
    }

    // Marks the icon a file dragged from a file manager will land on. Drawn
    // around the artwork so it reads as a target, not a selection.
    Rectangle {
      visible: appSlot.fileTarget
      x: window.iconInset - Style.space(3) * window.layoutScale
      y: window.iconInset - Style.space(3) * window.layoutScale
      width: window.iconSize + Style.space(6) * window.layoutScale
      height: window.iconSize + Style.space(6) * window.layoutScale
      radius: Style.cornerRadius * 0.7 * window.layoutScale
      color: "transparent"
      border.width: Math.max(2, Style.normalBorderWidth) * window.layoutScale
      border.color: Commons.Color.accent
      opacity: 0.9
    }

    Rectangle {
      visible: appSlot.notificationCount > 0
      x: window.iconInset + window.iconSize - width / 2
      y: window.iconInset - height / 2
      width: Math.max(Style.space(18), badgeText.implicitWidth + Style.spacing.xs * 2) * window.layoutScale
      height: Style.space(18) * window.layoutScale
      radius: height / 2
      color: Commons.Color.popups.background
      border.width: Math.max(1, Style.normalBorderWidth) * window.layoutScale
      border.color: Commons.Color.accent
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }

      Text {
        id: badgeText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: appSlot.notificationCount > 9 ? strings.t("dock.notificationOverflow").arg(Commons.I18n.formatNumber(9))
          : Commons.I18n.formatNumber(appSlot.notificationCount)
        color: Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        scale: window.layoutScale
      }
    }

    // A single short hop per launch; motion-reduction skips it entirely.
    SequentialAnimation {
      id: launchHop
      onRunningChanged: if (!running) appSlot.hopOffset = 0

      NumberAnimation { target: appSlot; property: "hopOffset"; from: 0; to: Style.space(14) * window.layoutScale; duration: Style.duration(400); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "hopOffset"; to: 0; duration: Style.duration(600); easing.type: Easing.OutCubic }
    }
  }

  BorderSurface {
    id: menu

    readonly property var item: window.menuItem
    readonly property var pickerItem: window.pickerKey ? window.workspaceItemsByKey[window.pickerKey] || null : null
    readonly property var entry: item && window.dock ? window.dock.entryFor(item) : null
    readonly property bool hasEntry: !!entry
    readonly property var actions: entry ? window.dock.appLibrary.quickActions(entry) : []
    readonly property bool hasNewWindowAction: actions.some(function(action) {
      return action.id === "new-window"
    })
    readonly property bool folder: !!item && item.type === "folder"
    readonly property bool running: !!item && item.windows.length > 0
    readonly property bool windowList: !!pickerItem
    readonly property var moveSource: window.moveAddress && window.dock
      ? window.dock.managedWindow(window.moveAddress) : null
    readonly property var windowRows: {
      if (!windowList || !window.dock) return []
      var dock = window.dock
      var monitorName = window.monitor ? window.monitor.name : ""
      if (window.moveAddress)
        return WorkspaceModel.destinations(dock.workspaceCatalog, dock.workspaceMonitors, monitorName, window.workspaceId, moveSource)
      return WorkspaceModel.rows(pickerItem.windows,
        dock.workspaceCatalog, dock.workspaceMonitors, monitorName, window.workspaceId)
    }
    readonly property bool stack: !!window.stackItem
    property bool resizeReady: false

    // Reset before opening, then animate ordinary menus from a compact height.
    // Folder stacks retain their initial size and expand as content arrives.
    function prepareResize() {
      resizeReady = false
      if (visible) Qt.callLater(armResize)
    }
    function armResize() {
      resizeReady = visible
    }
    onVisibleChanged: prepareResize()
    onItemChanged: prepareResize()
    onStackChanged: prepareResize()

    visible: window.contentShown && (!!item || window.settingsMenu || windowList || stack)
    clip: true
    // The most any popup can take without leaving the surface.
    readonly property int room: window.vertical
      ? window.popupRoom - window.gap * 2 : window.width - window.gap * 2
    width: stack
      ? Math.max(Style.space(160), Math.min(menuColumn.implicitWidth + padding * 2, Math.min(Style.space(340), room)))
      : windowList
        ? Math.min(Style.space(380), room)
        : actions.length > 0
          ? Math.min(Style.space(340), room, Math.max(Style.space(140), menuColumn.implicitWidth) + padding * 2)
          : Math.max(Style.space(140), menuColumn.implicitWidth) + padding * 2
    readonly property real targetHeight: menuColumn.implicitHeight + padding * 2
    height: stack || resizeReady ? targetHeight
      : Math.min(targetHeight, Style.spacing.popupRowHeight * 0.6 + padding * 2)
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    Behavior on width {
      enabled: menu.resizeReady && menu.visible
      NumberAnimation { duration: Style.duration(menu.stack ? 180 : 240); easing.type: Easing.OutCubic }
    }
    Behavior on height {
      enabled: menu.resizeReady && menu.visible
      NumberAnimation { duration: Style.duration(menu.stack ? 180 : 240); easing.type: Easing.OutCubic }
    }

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      Repeater {
        model: [["top", Commons.I18n.t("dock.positionTop")], ["bottom", Commons.I18n.t("dock.positionBottom")], ["left", Commons.I18n.t("dock.positionLeft")], ["right", Commons.I18n.t("dock.positionRight")]]

        delegate: MenuRow {
          required property var modelData

          visible: window.settingsMenu
          text: modelData[1]
          checked: window.position === modelData[0]
          onTriggered: Util.execDetached("omarchy-dock position " + modelData[0])
        }
      }

      MenuRow {
        visible: window.settingsMenu && !window.alwaysVisible
        text: Commons.I18n.t("dock.autoHide")
        checked: !!window.dock && window.dock.autohide
        onTriggered: Util.execDetached("omarchy-dock autohide " + (window.dock && window.dock.autohide ? "off" : "on"))
      }

      MenuRow {
        visible: window.settingsMenu
        text: strings.t("dock.alwaysVisible")
        checked: window.alwaysVisible
        onTriggered: window.dock.setAlwaysVisible(!window.alwaysVisible)
      }

      MenuRow {
        visible: window.settingsMenu
        text: strings.t("dock.workspaceOverview")
        closeOnTrigger: false
        onTriggered: window.openWorkspaceOverview()
      }

      MenuRow {
        visible: menu.running && !menu.folder
        text: strings.t("dock.workspaceWindows")
        closeOnTrigger: false
        onTriggered: window.openWindowPicker(menu.item, window.menuSlot)
      }

      MenuRow {
        visible: menu.hasEntry && menu.running && !menu.hasNewWindowAction
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: window.dock.launch(menu.item)
      }

      Flickable {
        id: actionList

        visible: menu.actions.length > 0
        width: parent.width
        implicitWidth: actionRows.implicitWidth
        height: visible ? Math.min(contentHeight, Style.spacing.popupRowHeight * 5) : 0
        contentHeight: actionRows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onVisibleChanged: if (visible) contentY = 0

        Column {
          id: actionRows
          width: actionList.width

          Repeater {
            model: menu.actions

            delegate: MenuRow {
              required property var modelData

              measured: true
              text: modelData.name
              iconSource: modelData.icon ? window.dock.appLibrary.iconSource(modelData.icon) : ""
              trailing: actionThumb.visible ? Style.space(6) : 0
              onTriggered: window.dock.appLibrary.launchAction(menu.entry, modelData)
            }
          }
        }

        Rectangle {
          id: actionThumb

          readonly property real trackHeight: Math.max(0, actionList.height - Style.space(4))
          visible: actionList.visible && actionList.contentHeight > actionList.height
          width: Math.max(2, Style.normalBorderWidth)
          height: visible ? Math.max(Style.space(16), trackHeight * actionList.visibleArea.heightRatio) : 0
          radius: width / 2
          color: Commons.Color.popups.text
          opacity: 0.25
          x: actionList.width - width - Style.space(2)
          y: actionList.contentY + Style.space(2) + Math.max(0, trackHeight - height)
            * actionList.contentY / Math.max(1, actionList.contentHeight - actionList.height)
        }
      }

      MenuRow {
        visible: menu.folder
        measured: true
        text: menu.item ? menu.item.name + " · " + menu.item.path : ""
        onTriggered: window.dock.launch(menu.item)
      }

      // Separate the folder heading from the contents and status below.
      Rectangle {
        visible: menu.stack
        width: parent.width
        height: visible ? Math.max(1, Style.normalBorderWidth) : 0
        color: Commons.Color.popups.border
        opacity: 0.5
      }

      MenuRow {
        visible: menu.stack && window.stackUnavailable
        text: "Folder unavailable"
        selectable: false
      }

      MenuRow {
        visible: menu.stack && !window.stackUnavailable && !window.stackLoading
          && window.stackEntries.length === 0
        text: "Empty folder"
        selectable: false
      }

      Flickable {
        id: stackFlick

        visible: menu.stack && window.stackEntries.length > 0
        opacity: window.stackLoading ? 0 : 1
        Behavior on opacity {
          enabled: menu.visible && menu.stack
          NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
        }
        width: parent.width
        implicitWidth: stackRows.implicitWidth
        // Eight entries plus the two actions stay inside the surface: any more
        // scrolls, with the thumb below showing there is more.
        height: visible ? Math.min(stackRows.implicitHeight, Style.spacing.popupRowHeight * 8) : 0
        contentHeight: stackRows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: stackRows
          width: parent.width

          Repeater {
            model: window.stackEntries

            delegate: MenuRow {
              required property var modelData

              measured: true
              text: modelData.name
              iconSource: window.stackIcon(modelData)
              // The thumb draws over the last few pixels; keep the label clear.
              trailing: Style.space(6)
              onTriggered: Util.execDetached("xdg-open " + Util.shellQuote(modelData.path))
            }
          }
        }

        // Only shown when the folder holds more than fits; the thumb size and
        // position track the visible fraction.
        Rectangle {
          readonly property bool needed: stackFlick.contentHeight > stackFlick.height + 1
          readonly property real trackHeight: stackFlick.height - Style.space(4)

          visible: needed
          width: Math.max(2, Style.normalBorderWidth)
          height: needed ? Math.max(Style.space(16), trackHeight * stackFlick.height / stackFlick.contentHeight) : 0
          radius: width / 2
          color: Commons.Color.popups.text
          opacity: 0.25
          x: stackFlick.width - width - Style.space(2)
          y: Style.space(2) + (trackHeight - height)
            * (stackFlick.contentY / Math.max(1, stackFlick.contentHeight - stackFlick.height))
        }
      }

      MenuRow {
        visible: menu.folder && !menu.item.fixed
        measured: true
        text: Commons.I18n.t("dock.removeFromDock")
        onTriggered: window.dock.removeFolder(menu.item)
      }

      MenuRow {
        visible: menu.hasEntry
        text: menu.item && menu.item.pinned ? Commons.I18n.t("dock.removeFromDock") : Commons.I18n.t("dock.keepInDock")
        onTriggered: window.dock.setPinned(menu.item.key, !menu.item.pinned, window.shownKeys())
      }

      MenuRow {
        visible: menu.running
        text: Commons.I18n.t("dock.quit")
        onTriggered: window.dock.quit(menu.item)
      }

      MenuRow {
        visible: menu.windowList && window.moveAddress !== ""
        text: strings.t("dock.workspaceBack")
        closeOnTrigger: false
        onTriggered: window.moveAddress = ""
      }

      MenuRow {
        visible: menu.windowList && !menu.windowRows.length
        selectable: false
        text: window.moveAddress ? strings.t("dock.workspaceNoDestinations") : strings.t("dock.workspaceNothing")
      }

      Flickable {
        id: windowListScroll
        visible: menu.windowList && !!menu.windowRows.length
        width: parent.width
        height: visible ? Math.min(pickerRows.implicitHeight, Style.spacing.popupRowHeight * 8) : 0
        contentHeight: pickerRows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onVisibleChanged: if (visible) contentY = 0
        Connections {
          target: window
          function onMoveAddressChanged() { windowListScroll.contentY = 0 }
          function onPickerKeyChanged() { windowListScroll.contentY = 0 }
        }

        Column {
          id: pickerRows
          width: parent.width

          Repeater {
            model: menu.windowRows

            delegate: MenuRow {
              required property var modelData
              readonly property bool windowRow: modelData.kind === "window"
              readonly property bool destination: modelData.kind === "destination"
              text: window.workspaceRowLabel(modelData, !window.moveAddress)
              heading: !windowRow && !destination
              indent: windowRow ? Style.spacing.md : 0
              selectable: windowRow || destination
              checked: windowRow && !!modelData.window.toplevel && modelData.window.toplevel.activated && !modelData.window.minimized
              actionText: windowRow && WorkspaceModel.canMove(modelData.window) ? strings.t("dock.workspaceMove") : ""
              onSecondaryTriggered: window.moveAddress = WorkspaceModel.address(modelData.window.address)
              onTriggered: {
                if (windowRow) window.dock.focusManagedWindow(modelData.window, window.workspaceId)
                else if (destination) window.dock.moveManagedWindow(window.moveAddress, modelData.space.id, modelData.space.monitor)
              }
            }
          }
        }
      }
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string text: ""
    property string iconSource: ""
    property bool checked: false
    property bool selectable: true
    property bool closeOnTrigger: true
    property bool heading: false
    property real indent: 0
    property string actionText: ""
    readonly property real actionSpace: actionText !== "" ? rowAction.width : 0
    // Extra room at the right for a scroll thumb or similar.
    property real trailing: 0
    // Opt-in natural width, used by folder stacks to fit their longest name.
    // Other menus keep their fixed width, as before.
    property bool measured: false
    signal triggered()
    signal secondaryTriggered()

    width: parent ? parent.width : 0
    implicitWidth: measured
      ? rowText.implicitWidth + rowText.anchors.leftMargin + rowText.anchors.rightMargin
      : 0
    height: visible ? Style.spacing.popupRowHeight : 0
    radius: Style.cornerRadius
    color: rowMouse.containsMouse && row.selectable ? Style.hoverFill : "transparent"
    opacity: selectable ? 1 : 0.6

    Image {
      id: rowIcon
      visible: row.iconSource !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(Style.font.body * 1.25)
      height: width
      sourceSize: Qt.size(width * 2, height * 2)
      source: row.iconSource
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
    }

    Text {
      id: rowText

      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.controlPaddingX + row.indent + (rowIcon.visible ? rowIcon.width + Style.spacing.sm : 0)
      anchors.rightMargin: Style.spacing.controlPaddingX + (row.checked ? Style.spacing.lg : 0) + row.trailing + row.actionSpace
      textFormat: Text.PlainText
      text: row.text
      elide: Text.ElideRight
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.bold: row.heading
      font.pixelSize: Style.font.body
    }

    Text {
      visible: row.checked
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX + row.actionSpace
      textFormat: Text.PlainText
      text: "✓"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: row.selectable
      cursorShape: row.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        row.triggered()
        if (row.closeOnTrigger) window.closeMenu()
      }
    }

    Rectangle {
      id: rowAction
      visible: row.actionText !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(parent.width / 3, actionLabel.implicitWidth + Style.spacing.controlPaddingX * 2)
      height: parent.height
      radius: Style.cornerRadius
      color: actionMouse.containsMouse ? Style.hoverFill : "transparent"

      Text {
        id: actionLabel
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.xs
        anchors.rightMargin: Style.spacing.xs
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: row.actionText
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        color: Commons.Color.popups.text
      }

      MouseArea {
        id: actionMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.secondaryTriggered()
      }
    }
  }
}
