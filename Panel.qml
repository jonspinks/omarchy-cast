import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// AirPlay bar widget: pick a television, pick how to use it, click.
//
// Modelled on the macOS Screen Mirroring menu, which is the experience Jon
// asked for: the receivers on the network, and for each one the three ways to
// use it — mirror this screen, use it as a second desktop, or send a single
// window. A live session shows what it is doing and offers one Stop.
//
// All the work goes through bin/airplay-ctl in this plugin, which owns the
// JSON shapes and the session lifecycle (a transient systemd user unit, so a
// shell reload cannot orphan a stream and Stop is a clean SIGTERM into the
// daemon's tested teardown).
Panel {
  id: root
  moduleName: "blacksheep.airplay"
  ipcTarget: "blacksheep.airplay"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  // Shipped inside the plugin, like blacksheep.worldclock's bin/, so that
  // `omarchy plugin add` on a fresh machine brings the control script along.
  readonly property string ctl: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/blacksheep.airplay/bin/airplay-ctl"

  property var state: ({})
  property var receivers: []
  property var windowList: []
  property bool busy: false
  property bool scanning: false

  // Which receiver's mode buttons are expanded. Empty means the list is
  // collapsed, as on a Mac before you choose a device.
  property string selectedHost: ""
  property string selectedName: ""
  property bool pickingWindow: false

  // Which receiver section is open: "", "video" or "audio". One at a time, so
  // the panel stays short however many speakers are on the network.
  property string openCategory: ""
  // Counts are only meaningful once a scan has run; before that the headers
  // show no number rather than a misleading 0.
  property bool hasScanned: false

  readonly property var videoReceivers: receivers.filter(function(r) { return r.display === true })
  readonly property var audioReceivers: receivers.filter(function(r) { return r.display !== true })

  // An open list scrolls past this height instead of growing the panel.
  readonly property real maxListHeight: Style.space(260)

  function toggleCategory(key) {
    if (root.openCategory === key) {
      root.openCategory = ""
    } else {
      root.openCategory = key
      root.selectedHost = ""
      root.pickingWindow = false
      // Opening a section is the moment to look, as on a Mac pulling down the
      // menu: the list reflects the network as it is now.
      root.scan(4)
    }
  }

  readonly property var session: state.session || null
  readonly property bool live: state.unit_active === true || session !== null
  readonly property var orphan: state.orphan || null
  readonly property string sessionKind: session && session.kind ? String(session.kind) : ""
  readonly property string sessionReceiver: session && session.receiver ? String(session.receiver) : ""

  readonly property string statusText: {
    if (orphan) return "A virtual output was left behind"
    if (!live) return "Not connected"
    var what = sessionKind === "extend" ? "second desktop"
             : sessionKind === "window" ? "one window"
             : sessionKind === "screen" || sessionKind === "output" ? "this screen"
             : "streaming"
    var where = receiverLabel(sessionReceiver)
    return where ? what + " → " + where : what
  }

  function receiverLabel(host) {
    if (!host) return ""
    for (var i = 0; i < receivers.length; i++) {
      if (receivers[i].host === host) return String(receivers[i].name || host)
    }
    return String(host)
  }

  function run(args, done) {
    var p = Qt.createQmlObject(
      'import Quickshell.Io; Process { stdout: StdioCollector { waitForEnd: true } }',
      root)
    p.stdout.streamFinished.connect(function() {
      var parsed = {}
      try { parsed = JSON.parse(String(p.stdout.text || "{}").trim() || "{}") } catch (e) { parsed = {} }
      if (done) done(parsed)
      p.destroy()
    })
    p.command = ["bash", "-lc", root.shellArg(root.ctl) + " " + args]
    p.running = true
  }

  function refresh() {
    run("status", function(s) { root.state = s || ({}) })
  }

  function scan(seconds) {
    if (root.scanning) return
    root.scanning = true
    run("discover " + (seconds || 4), function(d) {
      root.scanning = false
      root.hasScanned = true
      root.receivers = (d && d.receivers) ? d.receivers : []
    })
  }

  function loadWindows() {
    run("windows", function(d) { root.windowList = (d && d.windows) ? d.windows : [] })
  }

  function start(host, mode, target) {
    root.busy = true
    // A window title can contain quotes, spaces and non-ASCII, and this goes
    // through `bash -lc`, so it is single-quoted with embedded quotes escaped.
    run("start " + host + " " + mode + (target ? " " + shellArg(target) : ""), function() {
      root.busy = false
      root.selectedHost = ""
      root.pickingWindow = false
      refresh()
    })
  }

  function shellArg(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function stop() {
    root.busy = true
    run("stop", function() { root.busy = false; refresh() })
  }

  function cleanup() {
    root.busy = true
    run("cleanup", function() { root.busy = false; refresh() })
  }

  Component.onCompleted: { refresh(); }

  onOpenedChanged: {
    if (opened) {
      refresh()
      // No scan here: opening a Video or Audio section scans, so the network
      // is only swept when you actually look at a list.
      loadWindows()
    } else {
      // Roll everything up, so the next open starts short.
      selectedHost = ""
      pickingWindow = false
      openCategory = ""
    }
  }

  Timer {
    interval: root.opened ? 2000 : 6000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // U+F001F nf-md-airplay — the AirPlay mark itself. NOT md-television
    // (U+F0379): the stock Display panel uses that for a single screen, so
    // on the bar it read as a second copy of the same icon.
    text: "󰀟"
    active: root.orphan !== null
    tooltipText: "AirPlay — " + root.statusText
    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.scan(6)
        else if (t === "s" || t === "S") { if (root.live) root.stop() }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "AirPlay"
          meta: root.statusText
          detail: root.session && root.session.workspace
            ? "workspace " + root.session.workspace
            : ""
          iconOpacity: root.live ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰀟"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---- a leftover output, the one state worth shouting about ----
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.orphan !== null

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            text: "A virtual output is still on your desktop with no session behind it. "
                + "It rearranges your workspaces until it is cleared."
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            opacity: 0.7
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: root.busy ? "Cleaning up…" : "Clean it up"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.cleanup()
          }
        }

        // ---- a live session ----
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.live

          PanelSeparator { width: parent.width }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(14)
            rowSpacing: Style.space(6)

            InfoLabel { text: "Receiver" }
            InfoValue { text: root.receiverLabel(root.sessionReceiver) || "—"; Layout.fillWidth: true }

            InfoLabel { text: "Mode" }
            InfoValue {
              Layout.fillWidth: true
              text: root.sessionKind === "extend" ? "Second desktop"
                  : root.sessionKind === "window" ? "One window"
                  : root.sessionKind ? "This screen" : "—"
            }

            InfoLabel { text: "Workspace"; visible: !!(root.session && root.session.workspace) }
            InfoValue {
              visible: !!(root.session && root.session.workspace)
              Layout.fillWidth: true
              text: root.session && root.session.workspace ? String(root.session.workspace) : ""
            }
          }

          Button {
            text: root.busy ? "Stopping…" : "Stop"
            bordered: true
            foreground: root.bar ? root.bar.urgent : Color.urgent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.stop()
          }
        }

        // ---- the receivers, as two collapsible sections ----
        //
        // A home network with a dozen Sonos speakers pushed a single flat list
        // off the bottom of the screen. So receivers are split into Video and
        // Audio, only one section is open at a time, opening one scans the
        // network, clicking it again rolls it up, and each open list is capped
        // in height and scrolls rather than growing the panel.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.live

          PanelSeparator { width: parent.width }

          CategorySection {
            width: parent.width
            key: "video"
            title: "Video"
            items: root.videoReceivers
            emptyText: "No video receivers found. A Samsung Frame only announces itself "
                     + "when it is switched on, and can take a minute to join the network."
          }

          CategorySection {
            width: parent.width
            key: "audio"
            title: "Audio"
            items: root.audioReceivers
            emptyText: "No audio receivers found."
          }
        }

        // ---- audio, not yet implemented in the sender ----
        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            height: audioLabel.implicitHeight + Style.space(4)

            Text {
              id: audioLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Send audio"
              textFormat: Text.PlainText
              opacity: 0.4
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: false
              interactive: false
              opacity: 0.35
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }
          }

          Text {
            width: parent.width
            text: "Audio is proven but not yet ported to the sender — it lands with the "
                + "shared A/V clock and volume handling."
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            opacity: 0.5
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // A collapsible receiver section. The header shows the count once a scan has
  // run and a chevron for its state; clicking it opens and scans, or rolls it
  // up. The open list is capped at maxListHeight and scrolls.
  component CategorySection: Column {
    id: section
    property string key: ""
    property string title: ""
    property var items: []
    property string emptyText: ""
    readonly property bool isOpen: root.openCategory === key
    spacing: Style.space(4)

    Button {
      width: parent.width
      text: section.title
            + (root.hasScanned ? "  ·  " + section.items.length : "")
            + (root.scanning && section.isOpen ? "   scanning…" : "")
      // U+F0140 chevron-down when open, U+F0142 chevron-right (as stock uses)
      // when rolled up.
      iconText: section.isOpen ? "󰅀" : "󰅂"
      foreground: root.bar ? root.bar.foreground : Color.foreground
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      tooltipText: section.isOpen
        ? "Roll up"
        : "Scan for " + section.title.toLowerCase() + " receivers"
      onClicked: root.toggleCategory(section.key)
    }

    Flickable {
      width: parent.width
      visible: section.isOpen
      clip: true
      contentWidth: width
      contentHeight: list.implicitHeight
      height: Math.min(list.implicitHeight, root.maxListHeight)
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: list
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          visible: !root.scanning && root.hasScanned && section.items.length === 0
          text: section.emptyText
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.6
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: section.items
          ReceiverRow { width: list.width }
        }
      }
    }
  }

  // One receiver: its button, and on selection the three ways to use it (or
  // the window picker for the third).
  component ReceiverRow: Column {
    id: row
    required property var modelData
    spacing: Style.space(4)

    readonly property bool chosen: root.selectedHost === modelData.host
    // "yes" and "untested" can be tried; "no" (Apple TV, FairPlay) and
    // "audio" (speakers) would fail at setup, so they are shown for
    // completeness but cannot be selected.
    readonly property bool usable: modelData.support === "yes"
                                || modelData.support === "untested"

    Button {
      width: parent.width
      text: String(row.modelData.name || row.modelData.host)
            + (row.modelData.support === "untested" ? "  (untested)" : "")
      iconText: row.modelData.display ? "󰍹" : "󰕾"  // television or volume
      bordered: row.chosen
      selected: row.chosen
      opacity: row.usable ? 1.0 : 0.4
      foreground: root.bar ? root.bar.foreground : Color.foreground
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      tooltipText: String(row.modelData.host)
                 + (row.modelData.model ? " · " + row.modelData.model : "")
                 + (row.modelData.reason ? "\n" + row.modelData.reason : "")
      onClicked: {
        if (!row.usable) return
        if (row.chosen) {
          root.selectedHost = ""
          root.pickingWindow = false
        } else {
          root.selectedHost = String(row.modelData.host)
          root.selectedName = String(row.modelData.name || row.modelData.host)
          root.pickingWindow = false
        }
      }
    }

    // The three ways to use it, revealed on selection.
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: row.chosen && !root.pickingWindow
      leftPadding: Style.space(12)

      Button {
        text: "Use as second desktop"
        tooltipText: "A new workspace that exists only on the TV. Drag a window onto it "
                   + "and it keeps playing while you work elsewhere."
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onClicked: root.start(root.selectedHost, "extend", "")
      }

      Button {
        text: "Mirror this screen"
        tooltipText: "Everything on your laptop panel, scaled to the TV."
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onClicked: root.start(root.selectedHost, "screen", "")
      }

      Button {
        text: "Send one window…"
        tooltipText: "A single app. Note it freezes if its workspace is hidden — "
                   + "the second desktop is the better choice for something you watch."
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onClicked: { root.loadWindows(); root.pickingWindow = true }
      }
    }

    // Window picker for the third mode.
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: row.chosen && root.pickingWindow
      leftPadding: Style.space(12)

      PanelSectionHeader {
        text: "Which window?"
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      Repeater {
        model: root.windowList

        Button {
          required property var modelData
          width: parent.width
          text: String(modelData.title).length > 40
            ? String(modelData.title).substring(0, 39) + "…"
            : String(modelData.title)
          tooltipText: String(modelData.app) + " · " + String(modelData.title)
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.start(root.selectedHost, "window", String(modelData.title))
        }
      }

      Button {
        text: "Back"
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onClicked: root.pickingWindow = false
      }
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    opacity: 0.6
    color: root.bar ? root.bar.foreground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.bar ? root.bar.foreground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }
}
