import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "netshare.js" as Panel

// Bar icon and panel for the netshare controller. The panel follows the
// network panel: a hero with the switch on the right, then the adapter
// list. Left click opens it. The switch runs `netshare up` or `netshare down`
// with NETSHARE_PROMPT=desktop, so a missing sudo ticket opens a desktop
// password dialog. The command matches the position the switch is showing,
// so a stale off position cannot stop a tunnel the controller still has up.
// Names and addresses come from the live lookup.
Item {
  id: root

  property var bar: null
  property string moduleName: "netshare"
  property var settings: ({})

  property string iconText: "\uf0ec"
  property bool tunnelUp: false
  property string tunnelLabel: "down"
  property string posture: ""
  property string note: ""
  property string boundDevice: ""
  property string boundProxy: ""
  property string boundAddress: ""
  property string tunAddr: ""
  property var links: []
  property bool popoutSwitchClosing: false

  property bool toggleBusy: false
  property bool pendingUp: false
  property bool awaitState: false
  property bool refreshQueued: false
  property string toggleStderr: ""
  property string toggleError: ""

  // Same flag the other bar panels bind into KeyboardPanel.open.
  property bool opened: false
  readonly property bool switchOn: toggleBusy ? pendingUp : tunnelUp
  readonly property color ink: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(ink, 1.45)
  // BarIconButton.active paints bar.active, the attention grey. A connected
  // glyph uses the same bar foreground as the Wi-Fi icon.
  readonly property color barGlyph: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var orderedLinks: Panel.orderedLinks(links)

  readonly property int accessPointCount: Panel.accessPointCount(links)

  readonly property var accessPoint: Panel.accessPoint(links)

  readonly property var focusLink: Panel.focusLink({
    links: links,
    boundDevice: boundDevice,
    tunnelUp: tunnelUp,
    tunnelLabel: tunnelLabel
  })

  readonly property string heroTitle: {
    if (focusLink && focusLink.connection) return String(focusLink.connection)
    return "NetShare"
  }

  readonly property string shownProxy: Panel.shownProxy(focusLink, boundProxy)

  readonly property string metaText: Panel.metaText({
    toggleBusy: toggleBusy,
    pendingUp: pendingUp,
    tunnelLabel: tunnelLabel,
    tunnelUp: tunnelUp,
    posture: posture
  })

  readonly property string tunnelValue: {
    if (tunnelLabel === "stale") return "Stale"
    if (!tunnelUp) return "Down"
    if (tunAddr !== "") return tunAddr
    return "Up"
  }

  readonly property string noteText: {
    if (note === "ambiguous")
      return "More than one access point answered, so the tunnel will not start."
    if (note === "curl-missing")
      return "curl is not installed, so access points cannot be checked."
    return ""
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function firstError(raw) {
    var lines = String(raw || "").split("\n")
    var chosen = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf("netshare:") === 0)
        chosen = line.replace(/^netshare:\s*/, "")
    }
    if (chosen === "") {
      for (var j = 0; j < lines.length; j++) {
        var plain = lines[j].replace(/^\s+|\s+$/g, "")
        if (plain !== "") {
          chosen = plain
          break
        }
      }
    }
    if (chosen.length > 180) chosen = chosen.substring(0, 177) + "..."
    return chosen || "Toggle failed"
  }

  function applyOutput(raw) {
    var text = String(raw || "").trim()
    var data = {}
    if (text !== "") {
      var lines = text.split("\n")
      try {
        data = JSON.parse(lines[lines.length - 1])
      } catch (e) {
        data = {}
      }
    }
    root.iconText = data.text || "\uf0ec"
    var klass = data.class || ""
    root.tunnelLabel = data.tunnel || (klass === "active" ? "up" : "down")
    root.tunnelUp = root.tunnelLabel === "up" || klass === "active"
      || (Array.isArray(klass) && klass.indexOf("active") !== -1)
    root.posture = data.posture || ""
    root.note = data.note || ""
    root.boundDevice = data.boundDevice || ""
    root.boundProxy = data.boundProxy || ""
    root.boundAddress = data.boundAddress || ""
    root.tunAddr = data.tunAddr || ""
    root.links = Array.isArray(data.links) ? data.links : []

    if (root.awaitState) {
      if (root.refreshQueued) {
        root.refreshQueued = false
        poll.running = true
        return
      }
      root.awaitState = false
      root.toggleBusy = false
    } else if (root.refreshQueued && !root.toggleBusy) {
      root.refreshQueued = false
      poll.running = true
    }
  }

  function refresh() {
    if (root.toggleBusy) return
    if (poll.running) {
      root.refreshQueued = true
      return
    }
    poll.running = true
  }

  function finishToggle(code) {
    root.toggleError = code === 0 ? "" : root.firstError(root.toggleStderr)
    root.awaitState = true
    if (poll.running) root.refreshQueued = true
    else poll.running = true
  }

  function toggleTunnel() {
    if (root.toggleBusy || toggleProc.running) return
    root.toggleBusy = true
    root.toggleError = ""
    root.toggleStderr = ""
    root.pendingUp = !root.tunnelUp
    toggleProc.command = ["bash", "-lc", root.pendingUp ? "NETSHARE_PROMPT=desktop netshare up" : "NETSHARE_PROMPT=desktop netshare down"]
    toggleProc.running = true
  }

  function open() {
    root.popoutSwitchClosing = false
    root.opened = true
    root.refresh()
  }

  function close() {
    root.opened = false
  }

  function closeForPopoutSwitch() {
    root.popoutSwitchClosing = true
    root.close()
  }

  function togglePanel() {
    if (root.opened) root.close()
    else root.open()
  }

  Process {
    id: poll
    command: ["bash", "-lc", "netshare bar"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }
  }

  Process {
    id: toggleProc
    command: ["bash", "-lc", "NETSHARE_PROMPT=desktop netshare toggle"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.toggleStderr = text
    }
    onExited: function(code) {
      Qt.callLater(function() { root.finishToggle(code) })
    }
  }

  Timer {
    interval: 15000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    useActiveColor: false
    foreground: root.tunnelUp ? root.barGlyph : Qt.darker(root.barGlyph, 1.55)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }

  component LinkRow: CursorSurface {
    id: row
    property var link: ({})

    readonly property string networkName: {
      if (link && link.connection) return String(link.connection)
      if (link && link.ssid) return String(link.ssid)
      return ""
    }
    readonly property string adapterName: link && link.device ? String(link.device) : ""
    readonly property string addressText: link && link.address ? String(link.address) : ""
    readonly property bool accessPoint: !!(link && link.answer === "yes")
    readonly property bool inUse: !!(root.tunnelUp && adapterName !== "" && adapterName === root.boundDevice)
    readonly property string titleText: networkName !== "" ? networkName : (adapterName !== "" ? adapterName : "Adapter")
    readonly property string detailText: {
      var parts = []
      if (inUse) parts.push("In use")
      else if (accessPoint) parts.push("Proxy answered")
      else parts.push("No answer")
      if (link && link.ssid && String(link.ssid) !== networkName) parts.push(String(link.ssid))
      if (adapterName !== "") parts.push(adapterName)
      if (addressText !== "") parts.push(addressText)
      return parts.join("  ")
    }

    implicitHeight: rowBody.implicitHeight
    foreground: root.ink
    current: accessPoint

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: row.hasCursor = containsMouse
    }

    Item {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowIcon.implicitHeight, names.implicitHeight) + Style.spacing.rowPaddingX

      Text {
        id: rowIcon
        textFormat: Text.PlainText
        text: row.networkName !== "" ? "󰤨" : "󰈀"
        color: root.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: names
        spacing: Style.space(1)
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.titleText
          color: root.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: row.detailText !== ""
          textFormat: Text.PlainText
          text: row.detailText
          color: row.accessPoint ? root.ink : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.ink
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideLeft
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "\uf0ec"
            color: root.ink
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.accessPoint || root.tunnelUp || root.toggleBusy ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.switchOn
            busy: root.toggleBusy
            foreground: root.ink
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.toggleTunnel()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleBusy ? root.metaText : (root.tunnelUp ? "Turn the tunnel off" : "Turn the tunnel on")
              fontFamily: root.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.heroTitle
              color: root.ink
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.metaText.toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        Text {
          width: parent.width
          visible: root.toggleError !== ""
          textFormat: Text.PlainText
          text: root.toggleError
          wrapMode: Text.Wrap
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.noteText !== ""
          textFormat: Text.PlainText
          text: root.noteText
          wrapMode: Text.Wrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        GridLayout {
          visible: !!root.focusLink || root.tunnelUp || root.boundDevice !== ""
          width: parent.width
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          InfoLabel { text: "Connection" }
          InfoValue { text: root.focusLink && root.focusLink.connection ? String(root.focusLink.connection) : "--" }
          InfoLabel { text: "Adapter" }
          InfoValue { text: (root.focusLink && root.focusLink.device) ? String(root.focusLink.device) : (root.boundDevice || "--") }
          InfoLabel { text: "Address" }
          InfoValue { text: (root.focusLink && root.focusLink.address) ? String(root.focusLink.address) : (root.boundAddress || "--") }
          InfoLabel { text: "Proxy" }
          InfoValue { text: root.shownProxy || "--" }
          InfoLabel { text: "Tunnel" }
          InfoValue { text: root.tunnelValue }
        }

        PanelSeparator { foreground: root.ink }

        PanelSectionHeader {
          text: "NETWORKS"
          foreground: root.ink
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          visible: root.orderedLinks.length === 0
          textFormat: Text.PlainText
          text: "No NetShare network"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          id: networkList
          width: parent.width
          spacing: Style.space(4)
          visible: root.orderedLinks.length > 0

          Repeater {
            model: root.orderedLinks
            delegate: Item {
              required property var modelData
              width: networkList.width
              implicitHeight: linkRow.implicitHeight
              height: linkRow.implicitHeight

              LinkRow {
                id: linkRow
                anchors.left: parent.left
                anchors.right: parent.right
                link: modelData
              }
            }
          }
        }
      }
    }
  }
}
