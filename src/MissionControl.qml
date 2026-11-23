import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WorkspaceModel.js" as WorkspaceModel

OverlayWindow {
  id: root

  required property var dock
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  WlrLayershell.namespace: "omarchy-dock-mission-control"

  readonly property string monitorName: targetMonitor ? targetMonitor.name : ""
  readonly property int workspaceId: targetMonitor && targetMonitor.activeWorkspace ? targetMonitor.activeWorkspace.id : -1
  readonly property var layout: shown ? WorkspaceModel.missionLayout(dock.workspaceWindows,
    dock.workspaceCatalog, dock.workspaceMonitors, monitorName, workspaceId)
    : ({ workspaces: [], currentCards: [], otherCards: [] })
  readonly property string wallpaperLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaperPath: ""
  readonly property bool multipleMonitors: dock.workspaceMonitors.length > 1
  readonly property int gap: Style.spacing.lg
  readonly property int margin: Style.spacing.panelPadding
  readonly property var grid: WorkspaceModel.missionGrid(cards.count, stage.width, stage.height, Style.fontScale)
  property bool secondarySelected: false
  readonly property bool useSecondary: otherWindows.count > 0 && (secondarySelected || !cards.count)
  property string dragAddress: ""
  property point dragPoint
  property string dragTitle: ""
  readonly property var dragWindow: dragAddress ? dock.managedWindow(dragAddress) : null
  readonly property var dropSpace: dragWindow ? workspaceAt(dragPoint) : null

  function open(originScreen) {
    root.clearDrag()
    root.shown = true
    if (!wallpaperLookup.running) wallpaperLookup.running = true
    if (originScreen) root.targetScreen = originScreen
    root.secondarySelected = false
    Qt.callLater(function() {
      if (!root.shown) return
      workspaces.positionViewAtBeginning()
      cards.positionViewAtBeginning()
      otherWindows.positionViewAtBeginning()
      cards.currentIndex = cards.count ? 0 : -1
      otherWindows.currentIndex = otherWindows.count ? 0 : -1
      keys.forceActiveFocus()
    })
  }

  function close() {
    root.clearDrag()
    root.shown = false
    root.wallpaperPath = ""
  }

  function workspaceName(space) {
    if (!space) return strings.t("dock.workspaceUnknown")
    var number = Commons.I18n.formatNumber(space.fullId ? space.id : WorkspaceModel.slot(space.id))
    return strings.t("dock.workspaceNumber").arg(space.fullId ? "#" + number : number)
  }

  function location(space) {
    var name = root.workspaceName(space)
    return root.multipleMonitors && space && space.monitor
      ? strings.t("dock.workspaceOnMonitor").arg(name).arg(space.monitor) : name
  }

  function activate(card) {
    if (!card) return
    var current = root.workspaceId
    root.close()
    Qt.callLater(function() { root.dock.focusManagedWindow(card.window, current) })
  }

  function switchTo(space) {
    if (!space || !space.present) return
    root.close()
    Qt.callLater(function() { root.dock.focusManagedWorkspace(space.id) })
  }

  function workspaceAt(point) {
    // Hit-test actual delegates, not guessed slot offsets. This accounts for
    // tabs scrolled off-screen and the direction of a mirrored layout.
    var view = workspaces.mapFromItem(keys, point.x, point.y)
    if (view.x < 0 || view.y < 0 || view.x >= workspaces.width || view.y >= workspaces.height) return null
    var at = workspaces.contentItem.mapFromItem(keys, point.x, point.y)
    var target = workspaces.itemAt(at.x, at.y)
    return target && WorkspaceModel.canDrop(root.dragWindow, target.modelData) ? target.modelData : null
  }

  function navigate(key) {
    if (root.dragAddress || (!cards.count && !otherWindows.count)) return false
    var horizontal = key === Qt.Key_Left ? -1 : key === Qt.Key_Right ? 1 : 0
    if (horizontal) {
      var view = root.useSecondary ? otherWindows : cards
      view.currentIndex = Math.max(0, Math.min(view.count - 1, view.currentIndex + horizontal))
      view.positionViewAtIndex(view.currentIndex, root.useSecondary ? ListView.Contain : GridView.Contain)
    } else if (key === Qt.Key_Up && root.useSecondary && cards.count) {
      root.secondarySelected = false
    } else if (!root.useSecondary && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      var next = cards.currentIndex + (key === Qt.Key_Up ? -root.grid.columns : root.grid.columns)
      if (key === Qt.Key_Down && next >= cards.count && otherWindows.count) root.secondarySelected = true
      else {
        cards.currentIndex = Math.max(0, Math.min(cards.count - 1, next))
        cards.positionViewAtIndex(cards.currentIndex, GridView.Contain)
      }
    } else return false
    return true
  }

  function clearDrag() {
    root.dragAddress = ""
    root.dragTitle = ""
  }

  function finishDrag(point) {
    // Recheck the drop and compositor identity at release, not at drag start.
    var target = root.workspaceAt(point)
    var address = root.dragAddress
    root.clearDrag()
    if (target) root.dock.moveManagedWindow(address, target.id, target.monitor)
  }

  Process {
    id: wallpaperLookup
    command: ["readlink", "-e", "--", root.wallpaperLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = text.replace(/\n$/, "")
        if (root.shown && path.charAt(0) === "/" && !Util.isVideoPath(path)) root.wallpaperPath = path
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.menu.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.wallpaperPath ? Util.fileUrl(root.wallpaperPath) : ""
      sourceSize: Qt.size(Math.min(3200, Math.max(1, Math.ceil(width * root.devicePixelRatio))),
        Math.min(2000, Math.max(1, Math.ceil(height * root.devicePixelRatio))))
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      visible: status === Image.Ready
    }

    Rectangle {
      anchors.fill: parent
      visible: wallpaper.visible
      color: Util.alpha(Commons.Color.menu.background, 0.68)
    }
  }

  FocusScope {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.dragAddress) root.clearDrag()
        else root.close()
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (!root.dragAddress) root.activate(root.useSecondary ? root.layout.otherCards[otherWindows.currentIndex]
          : root.layout.currentCards[cards.currentIndex])
      } else if (!root.navigate(Util.readingKey(event))) return
      event.accepted = true
    }

    Column {
      anchors.fill: parent
      anchors.margins: root.margin
      spacing: root.gap

      Item {
        id: heading
        width: parent.width
        height: Math.max(Style.space(38), closeLabel.implicitHeight + Style.spacing.controlPaddingY * 2)

        Rectangle {
          anchors.right: parent.right
          width: closeLabel.implicitWidth + Style.spacing.controlPaddingX * 2
          height: heading.height
          radius: Style.cornerRadius
          color: closeMouse.containsMouse ? Style.hoverFill : Commons.Color.menu.selectedBackground
          MissionText {
            id: closeLabel
            anchors.centerIn: parent
            text: strings.t("dock.missionClose")
          }
          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }
        }
      }

      ListView {
        id: workspaces
        readonly property int tabWidth: Style.space(156)
        readonly property int tabHeight: Style.space(root.multipleMonitors ? 62 : 48)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width, count * tabWidth + Math.max(0, count - 1) * spacing)
        height: count ? tabHeight + (width < count * tabWidth + Math.max(0, count - 1) * spacing ? Style.space(10) : 0) : 0
        clip: true
        orientation: ListView.Horizontal
        spacing: root.gap
        model: root.layout.workspaces
        boundsBehavior: Flickable.StopAtBounds
        Controls.ScrollBar.horizontal: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: tab
          required property var modelData
          readonly property bool current: modelData.id === root.workspaceId
          readonly property bool landing: !!root.dropSpace && root.dropSpace.id === modelData.id
          readonly property bool available: WorkspaceModel.canDrop(root.dragWindow, modelData)
          width: workspaces.tabWidth
          height: workspaces.tabHeight
          radius: Style.cornerRadius
          color: tab.landing || tabMouse.containsMouse ? Style.hoverFill : Commons.Color.menu.selectedBackground
          border.color: tab.landing || tab.current ? Commons.Color.accent : Commons.Color.menu.selectedBorder
          border.width: tab.landing || tab.current ? Math.max(1, Style.normalBorderWidth) : 0
          opacity: root.dragAddress && !tab.available ? 0.55 : 1

          Column {
            width: parent.width - Style.spacing.controlPaddingX * 2
            anchors.centerIn: parent
            spacing: Style.spacing.xs
            Row {
              width: parent.width
              spacing: Style.spacing.xs
              MissionText {
                width: parent.width - (tab.current ? activeDot.width + parent.spacing : 0)
                text: root.workspaceName(tab.modelData)
                font.bold: tab.current
              }
              Rectangle {
                id: activeDot
                visible: tab.current
                width: Style.space(6)
                height: width
                anchors.verticalCenter: parent.verticalCenter
                radius: width / 2
                color: Commons.Color.accent
              }
            }
            MissionText {
              visible: root.multipleMonitors
              width: parent.width
              text: tab.modelData.monitor || strings.t("dock.workspaceUnknownMonitor")
              font.pixelSize: Style.font.bodySmall
            }
          }
          MouseArea {
            id: tabMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.switchTo(tab.modelData)
          }
        }
      }

      Item {
        id: stage
        width: parent.width
        height: Math.max(0, parent.height - heading.height - workspaces.height
          - shelf.height - parent.spacing * (shelf.visible ? 3 : 2))

        MissionText {
          anchors.centerIn: parent
          visible: !cards.count
          text: otherWindows.count ? strings.t("dock.missionCurrentEmpty") : strings.t("dock.missionEmpty")
        }

        GridView {
          id: cards
          anchors.centerIn: parent
          width: root.grid.width
          height: root.grid.height
          cellWidth: Math.max(1, root.grid.cellWidth)
          cellHeight: Math.max(1, root.grid.cellHeight)
          clip: true
          model: root.layout.currentCards
          delegate: windowCard
          boundsBehavior: Flickable.StopAtBounds
          Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
        }
      }

      Column {
        id: shelf
        width: parent.width
        visible: otherWindows.count > 0
        height: visible ? implicitHeight : 0
        spacing: Style.spacing.sm

        MissionText {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: strings.t("dock.missionOtherWindows")
          font.bold: true
        }

        ListView {
          id: otherWindows
          readonly property int cardWidth: Style.space(250)
          readonly property int cardHeight: Style.space(78)
          readonly property int desiredWidth: count * cardWidth + Math.max(0, count - 1) * spacing
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, desiredWidth)
          height: cardHeight + (width < desiredWidth ? Style.space(10) : 0)
          clip: true
          orientation: ListView.Horizontal
          spacing: Style.spacing.sm
          model: root.layout.otherCards
          delegate: windowCard
          boundsBehavior: Flickable.StopAtBounds
          Controls.ScrollBar.horizontal: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
        }
      }
    }

    Component {
      id: windowCard

      Item {
          id: cell
          required property int index
          required property var modelData
          readonly property bool compact: ListView.view === otherWindows
          readonly property bool selected: compact
            ? root.useSecondary && otherWindows.currentIndex === index
            : !root.useSecondary && cards.currentIndex === index
          width: compact ? Math.min(otherWindows.cardWidth, otherWindows.width) : cards.cellWidth
          height: compact ? otherWindows.cardHeight : cards.cellHeight
          readonly property var appWindow: modelData.window
          readonly property string address: WorkspaceModel.address(appWindow.address)
          readonly property string title: modelData.title || strings.t("dock.workspaceUntitled")
          readonly property bool lifted: !!address && root.dragAddress === address
          readonly property bool movable: WorkspaceModel.canMove(appWindow)
          readonly property bool previewEligible: !compact && root.shown && root.contentRevealed && !appWindow.minimized
            && appWindow.workspaceId === root.workspaceId && !!appWindow.toplevel && index < 6

          Rectangle {
            id: tile
            anchors.fill: parent
            anchors.margins: Math.max(1, root.gap / 2)
            radius: Style.cornerRadius
            color: cardMouse.containsMouse || cell.selected ? Style.hoverFill : Commons.Color.menu.selectedBackground
            border.width: cell.selected ? Math.max(1, Style.normalBorderWidth) : 0
            border.color: Commons.Color.accent
            opacity: cell.lifted ? 0.45 : 1

            Item {
              id: previewArea
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: cell.compact ? undefined : parent.right
              anchors.bottom: cell.compact ? parent.bottom : caption.top
              anchors.margins: root.gap
              width: cell.compact ? Style.space(40) : undefined
              clip: true

              Image {
                visible: !thumbnail.item || !thumbnail.item.hasContent
                anchors.centerIn: parent
                width: Math.min(parent.width, parent.height, Style.space(cell.compact ? 36 : 80))
                height: width
                source: root.dock.managedWindowIcon(cell.appWindow)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }
              Loader {
                id: thumbnail
                anchors.centerIn: parent
                readonly property real aspect: item && item.sourceSize.height > 0
                  ? item.sourceSize.width / item.sourceSize.height : 0
                width: aspect > 0 ? Math.min(parent.width, parent.height * aspect) : parent.width
                height: aspect > 0 ? width / aspect : parent.height
                active: cell.previewEligible
                sourceComponent: ScreencopyView {
                  id: capture
                  captureSource: cell.appWindow.toplevel
                  paintCursor: false
                  // Start asynchronously; a one-shot call during construction
                  // is too early for the compositor's recording context.
                  property bool captureFinished: false
                  live: !captureFinished
                  constraintSize: Qt.size(Math.min(1280, Math.max(1, previewArea.width)),
                    Math.min(800, Math.max(1, previewArea.height)))
                  opacity: hasContent ? 1 : 0
                  onHasContentChanged: if (hasContent) captureFinished = true
                  Timer {
                    running: !capture.captureFinished
                    interval: 1200
                    onTriggered: capture.captureFinished = true
                  }
                }
              }
            }

            Column {
              id: caption
              anchors.left: cell.compact ? previewArea.right : parent.left
              anchors.right: parent.right
              anchors.bottom: cell.compact ? undefined : parent.bottom
              anchors.verticalCenter: cell.compact ? parent.verticalCenter : undefined
              anchors.margins: root.gap
              spacing: Style.spacing.xs
              MissionText {
                width: parent.width
                text: cell.appWindow.minimized ? strings.t("dock.workspaceMinimized").arg(cell.title) : cell.title
                font.bold: true
              }
              MissionText {
                width: parent.width
                text: root.location(cell.modelData.space)
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: cardMouse
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: cell.movable
              cursorShape: cell.lifted ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              property point startPoint
              property bool moved: false
              onPressed: function(mouse) {
                startPoint = mapToItem(keys, mouse.x, mouse.y)
                moved = false
                root.secondarySelected = cell.compact
                if (cell.compact) otherWindows.currentIndex = cell.index
                else cards.currentIndex = cell.index
              }
              onPositionChanged: function(mouse) {
                if (!pressed || !cell.movable) return
                var point = mapToItem(keys, mouse.x, mouse.y)
                if (!moved && Math.hypot(point.x - startPoint.x, point.y - startPoint.y) < Style.space(8)) return
                if (!moved) {
                  moved = true
                  root.dragTitle = cell.title
                  root.dragAddress = cell.address
                }
                root.dragPoint = point
              }
              onReleased: function(mouse) {
                if (cell.lifted) root.finishDrag(mapToItem(keys, mouse.x, mouse.y))
              }
              onClicked: if (!moved) root.activate(cell.modelData)
              onCanceled: if (cell.lifted) root.clearDrag()
            }
          }
      }
    }

    Rectangle {
      visible: root.dragAddress !== ""
      width: Math.min(dragLabel.implicitWidth + Style.spacing.controlPaddingX * 2, Style.space(250))
      height: dragLabel.implicitHeight + Style.spacing.controlPaddingY * 2
      x: Math.max(0, Math.min(keys.width - width, root.dragPoint.x + root.gap))
      y: Math.max(0, Math.min(keys.height - height, root.dragPoint.y + root.gap))
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      border.color: Commons.Color.accent
      border.width: Math.max(1, Style.normalBorderWidth)
      MissionText {
        id: dragLabel
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.controlPaddingX
        verticalAlignment: Text.AlignVCenter
        text: root.dragTitle
        color: Commons.Color.popups.text
      }
    }
  }

  component MissionText: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    wrapMode: Text.NoWrap
    color: Commons.Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
