import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// AirPlay bar widget: pick a television, pick how to use it, click.
//
// Modelled on the macOS Screen Mirroring menu, which is the experience the user
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

  // ---- pairing ------------------------------------------------------------
  // A receiver can be set to demand a code shown on its own screen. The code
  // belongs to the CONNECTION that asked for it, so the sender has to hold one
  // socket open while you read the television — measured on a Frame, which
  // issued a code and then refused it when a second command submitted it. So
  // this is not "run a command with the code": it is start, wait for a human,
  // then answer on the same connection.
  property string pairingHost: ""
  property string pairingName: ""
  property bool pairingWaiting: false     // the code is on the TV, typing now
  property bool pairingBusy: false        // a request is in flight
  property string pairingError: ""

  readonly property var pairedHosts: state.paired || []
  function isPaired(host) { return pairedHosts.indexOf(String(host)) !== -1 }

  function pairStart(host, name) {
    root.pairingHost = String(host)
    root.pairingName = String(name || host)
    root.pairingError = ""
    root.pairingWaiting = false
    root.pairingBusy = true
    run("pair-start " + shellArg(host), function(r) {
      root.pairingBusy = false
      if (r && r.ok && r.prompt_shown) {
        root.pairingWaiting = true
      } else {
        root.pairingError = (r && r.error) ? String(r.error) : "the receiver did not answer"
        root.pairingHost = ""
      }
    })
  }

  function pairSubmit(code) {
    if (!root.pairingHost || String(code).length !== 4) return
    root.pairingBusy = true
    root.pairingError = ""
    run("pair-code " + shellArg(root.pairingHost) + " " + shellArg(code), function(r) {
      root.pairingBusy = false
      root.pairingWaiting = false
      if (r && r.ok && r.paired) {
        root.pairingHost = ""
        refresh()
      } else {
        // The receiver shows a NEW number after a refusal, so the only useful
        // next step is to ask for another code, not to retype this one.
        root.pairingError = (r && r.error) ? String(r.error) : "that code was not accepted"
        root.pairingHost = ""
      }
    })
  }

  function pairCancel() {
    var h = root.pairingHost
    root.pairingHost = ""
    root.pairingWaiting = false
    root.pairingBusy = false
    root.pairingError = ""
    // Cancelling closes the sender's input before a proof is built, so it does
    // not spend one of the receiver's few allowed attempts.
    if (h) run("pair-cancel " + shellArg(h), function() {})
  }

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
  // The running session's audio object (null when it sends none), straight
  // from `airplay status --json`: the truth about THIS session, whatever the
  // switch says about the next one.
  readonly property var sessionAudio: session && session.audio ? session.audio : null
  // Between `start` and bring-up the unit runs but has written no record yet.
  // An explicit, title-free boolean from airplay-ctl (`unit_audio`) is the
  // truth when it is there. Without it, fall back to the unit description,
  // "AirPlay <mode>[: <title>][ + audio] -> <host>" — anchored to its END,
  // because a window title can itself contain "+ audio" (host has no spaces).
  // A title that ENDS in " + audio" can still fool the fallback; only
  // `unit_audio` cannot be fooled.
  readonly property bool unitAudio: typeof state.unit_audio === "boolean"
    ? state.unit_audio
    : / \+ audio -> [^ ]+$/.test(String(state.unit_description || ""))
  readonly property bool liveWithAudio: sessionAudio !== null || (session === null && unitAudio)

  // "Send audio" for the NEXT session. Remembered by airplay-ctl across shell
  // reloads, and OFF until the user turns it on: audio moves the TV's volume, and
  // the Rust audio path has not been checked on the TV yet. `audioPending`
  // holds a click until the write lands, so a status poll in between cannot
  // throw the knob back.
  property var audioPending: null
  readonly property bool audioWanted: audioPending !== null ? audioPending : state.audio_pref === true

  function setAudioWanted(on) {
    root.audioPending = on
    run("audio-pref " + (on ? "on" : "off"), function(r) {
      root.audioPending = null
      if (r && r.ok) {
        var s = Object.assign({}, root.state)
        s.audio_pref = r.audio_pref === true
        root.state = s
      }
    })
  }

  // The compact line in the info grid. It is elided to one line, so a state
  // that needs a sentence gets a short token here and the sender's own words
  // in `audioProblem` underneath.
  function audioSummary(a) {
    if (!a) return "Off"
    var parts = [a.state === "streaming" ? "On" : "On (" + String(a.state) + ")"]
    // "silent": the sender streams digital silence because the TV volume is
    // not (yet) set from the laptop; a failed volume_state says why.
    var vs = String(a.volume_state || "")
    if (vs.indexOf("detached") === 0) {
      // The last level sent before the handover ended is still in the record
      // and is no longer true of anything; "TV silent" is the whole story.
      parts.push("TV silent")
      return parts.join(" · ")
    }
    if (vs.indexOf("error") === 0) parts.push("volume: error")
    else if (vs.indexOf("disabled") === 0) parts.push("volume: disabled")
    if (typeof a.tv_volume_db === "number")
      parts.push(a.tv_muted === true || a.tv_volume_db <= -144 ? "TV muted" : "TV " + a.tv_volume_db.toFixed(1) + " dB")
    else if (a.volume_sync === false)
      parts.push("volume not synced")
    return parts.join(" · ")
  }

  // The whole sentence behind a short token above, in the sender's own words
  // so the panel never has to guess at a cause. "" when nothing is wrong.
  function audioProblem(a) {
    if (!a) return ""
    var vs = String(a.volume_state || "")
    var bad = vs.indexOf("detached") === 0 || vs.indexOf("error") === 0
           || vs.indexOf("disabled") === 0
    return bad ? vs : ""
  }

  // WHERE this laptop's sound is coming out, which is the point of the
  // Mac-style handover and is not something "Audio: On" can say.
  //
  // In sink mode the sender publishes its own output (`output_sink`) and takes
  // it over only once the TV's volume has been established, so there are three
  // truthful states and the difference between them matters: BEFORE the
  // handover the speakers are still playing (deliberately — otherwise the
  // sound would be audible nowhere for those few seconds), AFTER it they are
  // quiet because the sound is going to the TV instead, and if the user picks
  // another output himself the sender gives ours up for good and the TV goes
  // silent.
  //
  // `output_sink` is null when the session is capturing the default sink's
  // monitor instead — either `--audio-capture pipewire` was asked for, or sink
  // mode fell back to it — and then the sound plays in both places at once.
  function audioOutputText(a) {
    if (!a || a.mode === "tone") return ""
    if (!a.output_sink)
      return a.capture === "pipewire" || a.capture === "parec"
           ? "The speakers as well as the TV" : ""
    if (String(a.volume_state || "").indexOf("detached") === 0)
      return "You changed the output — the TV is silent"
    if (a.output_is_default === true)
      return String(a.output_sink_label || a.output_sink) + " — the speakers are quiet"
    // Not handed over. Either it has not happened YET, or the volume side
    // failed and it never will — and "until" would be a lie in the second
    // case, which is the one the user would be staring at.
    return audioProblem(a) !== "" ? "The speakers — the output was never handed over"
                                  : "The speakers, until the TV's volume is set"
  }

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
    // This goes through `bash -lc`, so every argument is single-quoted with
    // embedded quotes escaped: a window title can hold anything, and the host
    // came off the network.
    // The target is always passed (empty for screen/extend) so the audio
    // choice lands in airplay-ctl's fifth argument.
    run("start " + shellArg(host) + " " + shellArg(mode) + " " + shellArg(target || "")
        + " audio=" + (root.audioWanted ? "on" : "off"), function() {
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

            InfoLabel { text: "Audio" }
            InfoValue { text: root.audioSummary(root.sessionAudio); Layout.fillWidth: true }

            // Only when there is something to say: a picture-only session has
            // no output of its own, and neither has a tone session.
            InfoLabel {
              text: "Sound out"
              visible: root.audioOutputText(root.sessionAudio) !== ""
            }
            InfoValue {
              visible: root.audioOutputText(root.sessionAudio) !== ""
              Layout.fillWidth: true
              text: root.audioOutputText(root.sessionAudio)
            }

            InfoLabel { text: "Workspace"; visible: !!(root.session && root.session.workspace) }
            InfoValue {
              visible: !!(root.session && root.session.workspace)
              Layout.fillWidth: true
              text: root.session && root.session.workspace ? String(root.session.workspace) : ""
            }
          }

          // The sender's own explanation, wrapped, when the audio side has
          // stopped doing what the row above implies: the volume never armed,
          // it was refused, or the user took the output back. The grid elides to
          // one line, and these are sentences.
          Text {
            width: parent.width
            visible: root.audioProblem(root.sessionAudio) !== ""
            text: root.audioProblem(root.sessionAudio)
                + (String(root.audioProblem(root.sessionAudio)).indexOf("detached") === 0
                   ? ". Restart the session to send sound again." : "")
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            opacity: 0.7
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
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

        // ---- send audio ----
        //
        // Honoured when a session STARTS. While one runs the switch shows what
        // that session is really doing and cannot be flipped: restarting would
        // tear down a second desktop and move its windows, and adding audio to
        // a live session has never been tried on the Frame.
        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width }

          Item {
            width: parent.width
            height: Math.max(audioLabel.implicitHeight, audioSwitch.implicitHeight)

            Text {
              id: audioLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Send audio"
              textFormat: Text.PlainText
              opacity: audioSwitch.interactive ? 1.0 : 0.6
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              id: audioSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.live ? root.liveWithAudio : root.audioWanted
              interactive: !root.live
              busy: root.busy || root.audioPending !== null
              opacity: interactive ? 1.0 : 0.5
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onToggled: if (!root.live) root.setAudioWanted(!root.audioWanted)
            }
          }

          Text {
            width: parent.width
            text: root.live
              ? "Applies to the next session."
              : root.audioWanted
                ? "This laptop's sound plays on the TV INSTEAD OF the speakers: the output "
                  + "switches to the TV while the session runs and switches back at the end. "
                  + "The volume keys and the TV remote stay in step. "
                  + "Lip sync is not yet calibrated for this TV."
                : "Picture only. Turn on to send this laptop's sound with it."
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
      leftAlign: true
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
      iconText: row.modelData.display ? "󰍹" : "󰕾"  // television or volume
      // U+F0341 key-variant marks a receiver we hold credentials for: it will
      // connect silently, with nothing appearing on its screen.
      text: String(row.modelData.name || row.modelData.host)
            + (row.modelData.support === "untested" ? "  (untested)" : "")
            + (root.isPaired(row.modelData.host) ? "  󰍁" : "")
      leftAlign: true
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

      // Pairing is only offered, never forced: most receivers connect without
      // a code, and this one is already paired if it carries the key mark.
      Button {
        text: root.isPaired(row.modelData.host) ? "Pair again…" : "Pair with a code…"
        tooltipText: root.isPaired(row.modelData.host)
          ? "Already paired — it connects silently. Pair again only if it starts asking for a code."
          : "For a receiver set to ask for a code. It shows four digits on its screen; type them here."
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onClicked: root.pairStart(row.modelData.host, row.modelData.name)
      }
    }

    // ---- the code entry -----------------------------------------------
    // Replaces the mode buttons while pairing, so there is one thing to do.
    Column {
      width: parent.width
      spacing: Style.space(6)
      visible: row.chosen && root.pairingHost === String(row.modelData.host)
      leftPadding: Style.space(12)

      Text {
        width: parent.width - Style.space(12)
        text: root.pairingBusy && !root.pairingWaiting
                ? "Asking " + root.pairingName + " to show a code…"
              : root.pairingWaiting
                ? "Type the four digits showing on " + root.pairingName + "."
              : ""
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        opacity: 0.7
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        spacing: Style.space(6)
        visible: root.pairingWaiting

        TextField {
          id: codeField
          width: Style.space(72)
          maximumLength: 4
          inputMethodHints: Qt.ImhDigitsOnly
          placeholderText: "0000"
          enabled: !root.pairingBusy
          foreground: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          onAccepted: root.pairSubmit(text)
          onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
        }

        Button {
          text: root.pairingBusy ? "…" : "Pair"
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.pairSubmit(codeField.text)
        }

        Button {
          text: "Cancel"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.pairCancel()
        }
      }
    }

    // A refusal means the receiver has already thrown that number away and is
    // showing a new one, so the only useful next step is to ask again.
    Text {
      width: parent.width
      visible: row.chosen && root.pairingError !== ""
      text: root.pairingError + "  Ask for a new code and try again."
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: root.bar ? root.bar.urgent : Color.urgent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
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
          leftAlign: true
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
