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
  property var outputs: []
  property bool popupOpen: false

  readonly property var streams: outputs.filter(output => output.kind === "virtual" && output.state === "on")

  readonly property string summary: displayState === "streaming"
    ? "External display: off — streaming to " + streams.map(output => output.label + " " + size(output.mode)).join(", ")
    : "External display: " + displayState

  readonly property var actions: displayState === "on"
    ? [
        { icon: "󰶐", label: "Turn off", args: ["off"] },
        { icon: "󱎫", label: "Turn off for 15 s", args: ["pause", "15"] }
      ]
    : displayState === "off"
    ? [
        { icon: "󰍹", label: "Turn on", args: ["on"] }
      ]
    : []

  function close() { popupOpen = false }

  function size(mode) { return mode.replace("x", "×") }

  function describe(output) {
    const detail = output.reason || size(output.mode)
    return detail ? output.state + " · " + detail : output.state
  }

  function parseOutputs(line) {
    try {
      const parsed = JSON.parse(line)
      return Array.isArray(parsed) ? parsed : []
    } catch (error) {
      return []
    }
  }

  function applyStatus(text) {
    const lines = text.trim().split("\n")
    displayState = lines[0] || "absent"
    outputs = parseOutputs(lines[1] || "")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function runMonitor(args) {
    close()
    Quickshell.execDetached(["sh", "-c", 'err=$(monitor "$@" 2>&1 >/dev/null) || notify-send Monitor "$(printf "%s" "$err" | tail -n 1)"', "sh"].concat(args))
    refreshSoon.restart()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["sh", "-c", "monitor auto >/dev/null 2>&1; monitor status; monitor outputs 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: root.applyStatus(text)
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
    text: root.displayState === "on" ? "󰍹" : root.displayState === "streaming" ? "󰄙" : "󰶐"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.summary
    onPressed: root.popupOpen = !root.popupOpen
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(280))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(4)

      Text {
        width: column.width
        textFormat: Text.PlainText
        text: root.summary
        wrapMode: Text.Wrap
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.outputs

        Item {
          id: outputRow
          required property var modelData

          width: column.width
          implicitHeight: Style.space(26)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: outputState.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: outputRow.modelData.label
            elide: Text.ElideRight
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            id: outputState
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.describe(outputRow.modelData)
            color: outputRow.modelData.state === "on" ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
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
