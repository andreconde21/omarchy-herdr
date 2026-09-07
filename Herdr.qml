import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Herdr workspace monitor: polls a Herdr server — the one on this machine, or
// one reached over ssh — and lists its workspaces with the agent state Herdr
// itself reports. Click a workspace to focus it; two clicks close it. Fails
// quiet when the server is unreachable or not running: the bar icon dims.
//
// Unlike a tmux widget, none of this is guesswork. Herdr classifies its own
// agents (idle/working/blocked/done/unknown) and exposes them over the CLI as
// JSON, so there are no pane-tail heuristics to drift out of date.
Panel {
  id: root
  moduleName: "andreconde.herdr"
  // Unique per configured target, so several instances (local + a server, say)
  // can live on the bar at once without their IPC handlers colliding.
  ipcTarget: "andreconde.herdr." + (root.host === "" ? "local" : root.host.replace(/[^A-Za-z0-9]/g, ""))
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // "" means the Herdr server on this machine; otherwise an ssh host/alias.
  readonly property string host: setting("host", "")
  readonly property int refreshMs: Math.max(10, setting("refreshIntervalSec", 20)) * 1000
  readonly property bool hideIdle: setting("hideIdle", false)
  readonly property string herdrPath: setting("herdrPath", "")

  readonly property bool isLocal: root.host === ""
  readonly property string label: root.isLocal ? "this machine" : root.host

  // workspaces: [{ id, number, label, status, statusLabel, agent, title,
  //                paneCount, tabCount, focused }]
  // status is one of: waiting | working | done | idle | unknown
  property var workspaces: []      // everything the server reported
  property var shown: []           // what the panel lists (honours hideIdle)
  property bool connected: false
  property bool everPolled: false
  property bool serverDown: false  // reachable, but no Herdr server running

  // Workspace id whose close button is armed.
  property string armedClose: ""

  readonly property int waitingCount: countStatus("waiting")
  readonly property int workingCount: countStatus("working")
  readonly property int doneCount: countStatus("done")

  function countStatus(s) {
    var n = 0
    for (var i = 0; i < workspaces.length; i++) if (workspaces[i].status === s) n++
    return n
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Text elements default to styled text, so anything that came off the wire
  // (workspace labels, agent titles, the host string) is escaped before it is
  // rendered. A label containing "<b>" should read as "<b>", not turn bold.
  function plainText(s) {
    return String(s === undefined || s === null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  // ------------------------------------------------------------- polling
  //
  // One call fetches both lists. `workspace list` carries the per-workspace
  // rollup; `agent list` carries which agent occupies which workspace and its
  // live state. They are fenced by a marker line rather than being two calls,
  // so a poll is a single round trip — over ssh that matters.

  // Quote for a POSIX shell.
  function sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  // Resolving the binary rather than trusting PATH is deliberate. A widget
  // runs from a NON-interactive shell, and the usual `[[ $- != *i* ]] && return`
  // guard at the top of ~/.bashrc means any PATH set there never applies. On a
  // machine carrying both a distro package (/usr/bin) and a newer user install
  // (~/.local/bin), bare `herdr` silently resolves to the older one — which
  // then fails every call with `protocol_mismatch` against a newer server.
  // Explicit setting wins; otherwise prefer the user install.
  readonly property string resolveBin:
    "H=" + sq(root.herdrPath) + "; "
    + "[ -z \"$H\" ] && { [ -x \"$HOME/.local/bin/herdr\" ] "
    + "&& H=\"$HOME/.local/bin/herdr\" || H=herdr; }; "

  readonly property string pollScript:
    root.resolveBin
    + "\"$H\" workspace list 2>/dev/null; echo '@@SPLIT@@'; \"$H\" agent list 2>/dev/null"

  // Wrap a herdr subcommand so it runs against the resolved binary, locally or
  // over ssh. Arguments are shell-quoted; ids are also validated at the call
  // site, so nothing user-typed reaches a shell unquoted.
  function herdrCommand(argsScript) {
    var script = root.resolveBin + "\"$H\" " + argsScript
    if (root.isLocal) return ["bash", "-c", script]
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", root.host, script]
  }

  readonly property var pollCommand: root.isLocal
    ? ["bash", "-c", root.pollScript]
    : ["ssh",
       "-o", "BatchMode=yes",
       "-o", "ConnectTimeout=5",
       "-o", "ServerAliveInterval=10",
       "-o", "ServerAliveCountMax=2",
       root.host,
       root.pollScript]

  function refresh() {
    if (!pollProc.running) pollProc.running = true
  }

  // Map Herdr's own vocabulary onto what the panel shows. "blocked" is the one
  // that earns the urgent colour: it means an agent is sitting on a permission
  // prompt or a question and cannot continue without André.
  function statusFor(agentStatus) {
    switch (agentStatus) {
      case "blocked": return { status: "waiting", label: "waiting" }
      case "working": return { status: "working", label: "working" }
      case "done":    return { status: "done",    label: "done" }
      case "idle":    return { status: "idle",    label: "idle" }
    }
    return { status: "unknown", label: "" }
  }

  // Parse once, into plain arrays. Nothing here runs from a binding, and no
  // date strings are parsed anywhere — both are load-bearing for shell health.
  function applyPoll(text) {
    root.everPolled = true

    var halves = String(text || "").split("@@SPLIT@@")
    var wsJson = halves.length > 0 ? halves[0].trim() : ""
    var agJson = halves.length > 1 ? halves[1].trim() : ""

    if (wsJson === "") {
      // Host answered but Herdr produced nothing: no server running, or the
      // binary is missing. Distinguish it from "cannot reach the host".
      root.connected = false
      root.serverDown = halves.length > 1
      root.workspaces = []
      root.shown = []
      return
    }

    var wsDoc, agDoc
    try { wsDoc = JSON.parse(wsJson) } catch (e) {
      root.connected = false; root.serverDown = true
      root.workspaces = []; root.shown = []
      return
    }
    try { agDoc = JSON.parse(agJson) } catch (e2) { agDoc = null }

    var wsList = (wsDoc && wsDoc.result && wsDoc.result.workspaces) || []
    var agList = (agDoc && agDoc.result && agDoc.result.agents) || []

    // workspace_id -> agent, so a row can show what is actually running.
    var byWorkspace = {}
    for (var a = 0; a < agList.length; a++) {
      var ag = agList[a]
      if (ag && ag.workspace_id && !byWorkspace[ag.workspace_id]) byWorkspace[ag.workspace_id] = ag
    }

    var out = []
    for (var i = 0; i < wsList.length; i++) {
      var w = wsList[i]
      var ag2 = byWorkspace[w.workspace_id]
      // The agent's own state wins; the workspace rollup is the fallback for
      // workspaces holding a plain shell.
      var raw = (ag2 && ag2.agent_status) || w.agent_status || "unknown"
      var st = root.statusFor(raw)
      out.push({
        id: w.workspace_id,
        number: w.number,
        label: w.label || w.workspace_id,
        status: st.status,
        statusLabel: st.label,
        agent: ag2 ? (ag2.agent || "") : "",
        title: ag2 ? (ag2.terminal_title_stripped || "") : "",
        paneCount: w.pane_count || 0,
        tabCount: w.tab_count || 0,
        focused: w.focused === true
      })
    }

    root.workspaces = out
    root.rebuildShown()
    root.connected = true
    root.serverDown = false
  }

  // Kept as an explicit rebuild rather than a binding over the model, so the
  // filter cost is paid once per poll instead of on every property read.
  function rebuildShown() {
    if (!root.hideIdle) { root.shown = root.workspaces; return }
    var out = []
    for (var i = 0; i < root.workspaces.length; i++) {
      var s = root.workspaces[i].status
      if (s === "waiting" || s === "working" || s === "done") out.push(root.workspaces[i])
    }
    root.shown = out
  }

  onHideIdleChanged: root.rebuildShown()
  onHostChanged: {
    root.connected = false
    root.everPolled = false
    root.workspaces = []
    root.shown = []
    root.refresh()
  }

  // -------------------------------------------------------------- actions

  // Herdr's public ids are short and alphanumeric (w1, wA, w1:t1). Anything
  // else did not come from Herdr, so it never reaches a command line.
  function isSafeId(id) { return /^[A-Za-z0-9:_-]{1,64}$/.test(String(id)) }

  // Clicking a row opens that workspace in a terminal, the way attaching to a
  // tmux window did. Focus is set on the server first so the client that comes
  // up lands on the workspace you clicked, not wherever focus happened to be.
  function openWorkspace(id) {
    if (!root.isSafeId(id)) return
    var script = root.resolveBin
      + "\"$H\" workspace focus " + id + " >/dev/null 2>&1; exec \"$H\""
    if (root.isLocal) {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "bash", "-c", script])
    } else {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec",
                               "ssh", "-t", root.host, script])
    }
    root.close()
  }

  // Open a client. Local runs the resolved binary; remote goes through ssh -t.
  function openClient() {
    if (root.isLocal) {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec",
                               "bash", "-c", root.resolveBin + "exec \"$H\""])
    } else {
      Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec",
                               "ssh", "-t", root.host, root.resolveBin + "exec \"$H\""])
    }
    root.close()
  }

  // Destructive, so two clicks: the first arms this workspace's button (it
  // turns urgent), the second closes it. Arming decays on its own.
  function requestClose(id) {
    if (!root.isSafeId(id)) return
    if (root.armedClose !== id) {
      root.armedClose = id
      disarmTimer.restart()
      return
    }
    root.armedClose = ""
    disarmTimer.stop()
    closeProc.command = root.herdrCommand("workspace close " + id)
    closeProc.running = true
  }

  // ------------------------------------------------------------ processes

  Process {
    id: pollProc
    running: false
    command: root.pollCommand

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPoll(text)
    }
    // Offline is expected, not news. Swallow stderr.
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      // Non-zero with no usable stdout means we never reached a Herdr server.
      if (code !== 0 && !root.connected) { root.everPolled = true; root.serverDown = false }
    }
  }

  Process {
    id: closeProc
    running: false
    onExited: root.refresh()
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: pollTimer
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: disarmTimer
    interval: 3000
    onTriggered: root.armedClose = ""
  }

  onOpenedChanged: if (opened) {
    armedClose = ""
    refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ------------------------------------------------------------- bar icon

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.connected ? " " + root.workspaces.length : ""
    fontSize: Style.bar.iconFont
    dimmed: !root.connected
    // Urgent only when an agent is blocked on the user — the one state that
    // actually needs him. Working agents are busy, not waiting.
    active: root.connected && root.waitingCount > 0
    tooltipText: root.connected
      ? root.plainText(root.label) + " · " + root.workspaces.length + " workspace"
        + (root.workspaces.length === 1 ? "" : "s")
        + " · " + root.waitingCount + " waiting / " + root.workingCount + " working"
      : (root.serverDown ? "No Herdr server on " + root.plainText(root.label)
                         : root.plainText(root.label) + " unreachable")
    onPressed: root.toggle()
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentY + dy * Style.space(56),
                                                     Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "o" || t === "O") root.openClient()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: root.plainText(root.label)
            meta: root.connected
              ? root.workspaces.length + " workspace" + (root.workspaces.length === 1 ? "" : "s")
                + " · " + root.waitingCount + " waiting · " + root.workingCount + " working"
              : (!root.everPolled ? "connecting…"
                                  : (root.serverDown ? "no Herdr server" : "unreachable"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.4

            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: ""
                tooltipText: "Refresh now"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          Text {
            visible: root.everPolled && !root.connected
            width: parent.width
            topPadding: Style.space(16)
            text: root.serverDown
              ? "No Herdr server running on " + root.plainText(root.label) + ".\nStart one with 'herdr'."
              : "Can't reach " + root.plainText(root.label) + ".\nRetrying every "
                + Math.round(root.refreshMs / 1000) + "s."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.connected && root.workspaces.length === 0
            width: parent.width
            topPadding: Style.space(16)
            text: "Connected — no workspaces open."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.connected && root.workspaces.length > 0 && root.shown.length === 0
            width: parent.width
            topPadding: Style.space(16)
            text: "All " + root.workspaces.length + " workspaces are idle."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.shown

            WorkspaceRow {
              required property var modelData
              width: column.width
              ws: modelData
            }
          }

          Text {
            visible: root.connected && root.shown.length > 0
            width: parent.width
            topPadding: Style.space(4)
            text: "Click to open · close needs 2 clicks · r refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One Herdr workspace: number, label, what is running in it, status, close.
  component WorkspaceRow: Item {
    id: wsRow
    property var ws: null

    readonly property string status: ws ? ws.status : "idle"
    readonly property bool closeArmed: ws && root.armedClose === ws.id
    // waiting is urgent; working is normal foreground; done is the accent;
    // idle and unknown stay quiet.
    readonly property color statusColor: status === "waiting" ? root.urgent
      : status === "working" ? root.foreground
      : status === "done" ? Color.accent
      : root.dim

    implicitHeight: Math.max(nameText.implicitHeight + subText.implicitHeight + Style.spacing.xs,
                             Style.spacing.controlHeight) + Style.spacing.md

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowMouse.containsMouse ? root.alpha(root.foreground, 0.10) : root.alpha(root.foreground, 0.04)
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (wsRow.ws) root.openWorkspace(wsRow.ws.id)
    }

    Text {
      id: numberText
      text: wsRow.ws ? wsRow.ws.number : ""
      color: wsRow.ws && wsRow.ws.focused ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      width: Style.space(16)
      horizontalAlignment: Text.AlignHCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      anchors.left: numberText.right
      anchors.leftMargin: Style.space(6)
      anchors.right: statusChip.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        id: nameText
        width: parent.width
        text: wsRow.ws ? root.plainText(wsRow.ws.label) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: subText
        width: parent.width
        // Prefer what the agent calls itself; fall back to the agent kind, then
        // to the raw pane count.
        text: {
          if (!wsRow.ws) return ""
          if (wsRow.ws.title !== "") return root.plainText(wsRow.ws.title)
          if (wsRow.ws.agent !== "") return root.plainText(wsRow.ws.agent)
          return wsRow.ws.paneCount + " pane" + (wsRow.ws.paneCount === 1 ? "" : "s")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Rectangle {
      id: statusChip
      anchors.right: closeButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: wsRow.ws && wsRow.ws.statusLabel !== ""
      width: chipText.implicitWidth + Style.space(12)
      height: chipText.implicitHeight + Style.space(6)
      radius: height / 2
      color: wsRow.status === "waiting"
        ? root.alpha(root.urgent, 0.22)
        : wsRow.status === "working"
        ? root.alpha(root.foreground, 0.16)
        : wsRow.status === "done"
        ? root.alpha(Color.accent, 0.10)
        : root.alpha(root.foreground, 0.06)

      Text {
        id: chipText
        anchors.centerIn: parent
        text: wsRow.ws ? wsRow.ws.statusLabel : ""
        color: wsRow.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
        font.bold: wsRow.status === "waiting" || wsRow.status === "working" || wsRow.status === "done"
      }
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: ""
      fontSize: Style.font.caption
      foreground: wsRow.closeArmed ? root.urgent : root.dim
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      tooltipText: wsRow.closeArmed
        ? "Click again to close workspace '" + (wsRow.ws ? wsRow.ws.label : "") + "'"
        : "Close workspace (two clicks)"
      onClicked: if (wsRow.ws) root.requestClose(wsRow.ws.id)
    }
  }
}
