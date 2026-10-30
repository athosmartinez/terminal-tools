import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "terminal-tools.monitor"

  property string displayState: "absent"
  property bool popupOpen: false

  readonly property var actions: displayState === "on"
    ? [
        { icon: "󰶐", label: "Turn off", args: ["off"] },
        { icon: "󱎫", label: "Turn off for 15 s", args: ["pause", "15"] }
      ]
    : [
        { icon: "󰍹", label: "Turn on", args: ["on"] }
      ]

  function close() { popupOpen = false }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function runMonitor(args) {
    close()
    Quickshell.execDetached(["sh", "-c", 'err=$(monitor "$@" 2>&1 >/dev/null) || notify-send Monitor "$(printf "%s" "$err" | tail -n 1)"', "sh"].concat(args))
    refreshSoon.restart()
  }

  visible: displayState !== "absent"
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["sh", "-c", "monitor auto >/dev/null 2>&1; monitor status"]
    stdout: StdioCollector {
      onStreamFinished: root.displayState = text.trim() || "absent"
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: refreshSoon
    interval: 700
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name.startsWith("monitor") || event.name === "configreloaded") refreshSoon.restart()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayState === "on" ? "󰍹" : "󰶐"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "External display: " + root.displayState
    onPressed: root.popupOpen = !root.popupOpen
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(220))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        text: "External display: " + root.displayState
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.actions

        CursorSurface {
          id: actionRow
          required property var modelData

          width: column.width
          implicitHeight: Style.space(40)
          radius: Style.spacing.labelGap
          foreground: root.bar.foreground
          hasCursor: actionArea.containsMouse

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              text: actionRow.modelData.icon
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              text: actionRow.modelData.label
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            id: actionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runMonitor(actionRow.modelData.args)
          }
        }
      }
    }
  }
}
