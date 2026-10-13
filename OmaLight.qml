import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search
import "Strings.js" as Strings

// OmaLight: a Spotlight-style bar for Omarchy, after Lumi (github.com/AlbertS15/Lumi).
// One input finds apps and files, or asks Claude and streams the answer in place.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.kostya9406.omalight"
  readonly property string home: Quickshell.env("HOME")
  // Claude runs from here, so its sessions stay out of real projects.
  readonly property string stateDir: root.home + "/.local/state/omalight"
  // The alias always resolves to the newest Haiku; override with {"model": "..."} in the summon payload.
  property string model: "haiku"

  readonly property string systemPrompt:
    "You were called from OmaLight, a Spotlight-style quick bar on Omarchy Linux (Arch, Hyprland). " +
    "Answer briefly and to the point, in the language of the question. Start with the answer itself; " +
    "no filler, no restating the question, no offers of more help. " +
    "Use Markdown only for lists, bold and code. If you are unsure or need fresh facts, say so or search the web."

  property bool opened: false
  // "ru" or "en" from the summon payload; otherwise the system locale decides.
  property string lang: ""
  readonly property bool ru: root.lang ? root.lang === "ru" : Strings.isRussian(Qt.locale().name)
  function tr(key) { return Strings.tr(key, root.ru) }
  property string query: ""

  // Search mode.
  property var apps: []
  property var files: []
  property string filesQuery: ""
  property var rows: []
  property int selectedIndex: 0
  property bool userMoved: false

  // Answer mode: the conversation so far, newest last.
  property var turns: []
  property bool answering: false
  property string sessionId: ""
  property string notice: ""
  // The answer being streamed. It joins `turns` only when the run ends, so a
  // token never rebuilds the whole conversation; pieces are flushed every 50 ms.
  property string liveAnswer: ""
  property string liveBuffer: ""
  property string hoveredLink: ""
  readonly property bool hasAnswer: root.turns.length > 0

  // Theme: the same [menu] surface tokens the Omarchy menu and emoji picker use.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color accent: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int inputHeight: Math.max(Style.space(40), Style.font.display + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Math.max(Style.space(40), Style.font.title * 2 + Style.spacing.md)
  property int maxRows: 9
  property int cardWidth: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)

  // MARK: lifecycle

  function open(payloadJson) {
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && (payload.lang === "ru" || payload.lang === "en")) root.lang = payload.lang
      if (payload && typeof payload.model === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(payload.model)) root.model = payload.model
    } catch (e) {
    }
    root.resetConversation()
    root.setQuery("")
    root.opened = true
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopAnswer()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // MARK: search

  function setQuery(text) {
    root.query = text
    if (input.text !== text) input.text = text
    if (root.hasAnswer) return
    var q = text.trim()
    root.apps = q ? Search.searchApps(DesktopEntries.applications.values || [], q) : []
    root.userMoved = false
    root.rebuildRows()
    root.selectedIndex = Search.looksLikeQuestion(q) || root.rows.length < 2 ? 0 : 1
    if (q.length >= 2) fileDebounce.restart()
    else { fileDebounce.stop(); root.files = []; root.filesQuery = "" }
  }

  function rebuildRows() {
    var q = root.query.trim()
    if (!q) { root.rows = []; return }
    var out = [{ kind: "ask", title: root.tr("ask"), subtitle: q }]
    for (var i = 0; i < root.apps.length; i++) {
      var e = root.apps[i]
      out.push({ kind: "app", title: String(e.name || e.id), subtitle: String(e.genericName || e.comment || root.tr("app")),
                 icon: String(e.icon || ""), id: String(e.id || "") })
    }
    if (root.filesQuery === q) {
      for (var j = 0; j < root.files.length; j++) {
        var f = root.files[j]
        out.push({ kind: "file", title: Search.baseName(f.path), subtitle: Search.tildify(Search.dirName(f.path), root.home),
                   path: f.path, dir: f.dir })
      }
    }
    root.rows = out
    pointerGate.reset()
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
  }

  function onFilesArrived(q, output) {
    root.files = Search.filterFiles(output, root.home, q)
    root.filesQuery = q
    if (root.hasAnswer || q !== root.query.trim()) return
    root.rebuildRows()
    // A search lands on the first app or file; a question stays on the ask row.
    if (!root.userMoved && !Search.looksLikeQuestion(q) && root.selectedIndex === 0 && root.rows.length > 1)
      root.selectedIndex = 1
  }

  function startFileSearch() {
    var q = root.query.trim()
    if (q.length < 2 || root.hasAnswer) return
    if (fileProc.running) return // onExited picks the newest query up
    fileProc.searched = q
    fileProc.command = ["bash", "-c",
      // The first line names the query, so the output can never be matched to a newer one.
      'printf "q\\t%s\\n" "$1"; ' +
      // Directories get a "d" tag so the row can show a folder; hidden paths and
      // anything outside home are dropped before the cut so they cannot crowd it.
      'plocate -i -b -- "$1" 2>/dev/null | grep -F "$HOME/" | grep -v -e "/\\." -e "/node_modules/" | head -n 300 |' +
      ' while IFS= read -r p; do if [ -d "$p" ]; then printf "d\\t%s\\n" "$p"; else printf "f\\t%s\\n" "$p"; fi; done',
      "bash", q]
    fileProc.running = true
  }

  function move(delta) {
    if (root.rows.length === 0) return
    root.userMoved = true
    root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    results.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate(index, reveal) {
    var row = root.rows[index]
    if (!row) return
    if (row.kind === "ask") { root.ask(row.subtitle); return }
    if (row.kind === "app") {
      if (reveal) return
      root.run(["uwsm-app", "--", "gtk-launch", row.id + ".desktop"])
    } else if (row.kind === "file") {
      root.run(["uwsm-app", "--", "xdg-open", reveal && !row.dir ? Search.dirName(row.path) : row.path])
    }
    root.dismiss()
  }

  // argv only ever lands in bash's positional parameters, so nothing typed is re-parsed.
  function run(argv) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  // MARK: asking Claude

  function ask(question) {
    var q = String(question || "").trim()
    if (!q) return
    fileDebounce.stop()
    // A new question while one is still answering ends that one where it is.
    if (root.answering) root.finishTurn(root.tr("interrupted"))
    var turns = root.turns.slice()
    turns.push({ q: q, a: "", error: "" })
    root.turns = turns
    root.notice = ""
    root.followAnswer = true
    root.query = ""
    input.text = ""
    var args = ["--safe-mode", "-p", "--model", root.model,
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch",
                "--append-system-prompt", root.systemPrompt]
    if (root.sessionId) args.push("--resume", root.sessionId)
    var command = ["bash", "-lc",
      // The question goes in on stdin, never through a shell; exec so stopping the run stops claude.
      'd=$1; q=$2; shift 2; mkdir -p "$d" && cd "$d" || exit 1; exec claude "$@" <<<"$q"',
      "bash", root.stateDir, q].concat(args)
    if (askProc.running) {
      askProc.pending = command
      askProc.running = false
    } else {
      root.startAsk(command)
    }
  }

  function startAsk(command) {
    root.answering = true
    root.liveAnswer = ""
    root.liveBuffer = ""
    askProc.streamed = false
    askProc.failed = ""
    askProc.command = command
    askProc.running = true
  }

  function updateLastTurn(change) {
    if (root.turns.length === 0) return
    var turns = root.turns.slice()
    var last = Object.assign({}, turns[turns.length - 1])
    change(last)
    turns[turns.length - 1] = last
    root.turns = turns
  }

  function onStreamLine(line) {
    // While a replaced run winds down its lines belong to no turn.
    if (askProc.pending || !root.answering) return
    var ev = Search.parseStreamLine(line)
    if (!ev) return
    if (ev.kind === "session") {
      root.sessionId = ev.id
    } else if (ev.kind === "text") {
      askProc.streamed = true
      root.liveBuffer += ev.text
      if (!flushTimer.running) flushTimer.start()
    } else if (ev.kind === "full") {
      // After a tool call the next text block streams on its own; keep blocks apart.
      if (!askProc.streamed && ev.text) root.liveBuffer += ev.text
      else if (ev.text && !/\n\n$/.test(root.liveAnswer + root.liveBuffer)) root.liveBuffer += "\n\n"
      if (!flushTimer.running) flushTimer.start()
    } else if (ev.kind === "error") {
      askProc.failed = ev.text
    }
  }

  function flushLive() {
    if (!root.liveBuffer) return
    root.liveAnswer += root.liveBuffer
    root.liveBuffer = ""
  }

  // Moves the streamed answer into the conversation; `why` marks a turn left without one.
  function finishTurn(why) {
    flushTimer.stop()
    root.flushLive()
    var answer = root.liveAnswer.replace(/\s+$/, "")
    root.answering = false
    root.liveAnswer = ""
    root.updateLastTurn(function(t) {
      t.a = answer
      if (!answer && !t.error) t.error = why
    })
  }

  function onAskExited(exitCode) {
    if (askProc.pending) {
      var next = askProc.pending
      askProc.pending = null
      root.startAsk(next)
      return
    }
    if (!root.answering) return
    var failed = askProc.failed || (exitCode !== 0 && !(root.liveAnswer + root.liveBuffer).trim())
    if (failed) {
      var err = Search.explainError(askProc.failed || askErr.text.trim() || (root.tr("exitCode") + exitCode))
      var why = (err.key ? root.tr(err.key) : "") + err.detail
      root.finishTurn("")
      root.updateLastTurn(function(t) { t.error = why })
    } else {
      root.finishTurn(root.tr("empty"))
    }
  }

  function stopAnswer() {
    askProc.pending = null
    if (askProc.running) askProc.running = false
    if (root.answering) root.finishTurn(root.tr("stopped"))
  }

  function resetConversation() {
    root.stopAnswer()
    root.turns = []
    root.sessionId = ""
    root.notice = ""
  }

  function copyAnswer() {
    for (var i = root.turns.length - 1; i >= 0; i--) {
      if (root.turns[i].a) {
        Quickshell.clipboardText = root.turns[i].a
        root.notice = root.tr("copied")
        noticeTimer.restart()
        return
      }
    }
  }

  // MARK: keys

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter

    if (event.key === Qt.Key_Escape) {
      if (root.answering) root.stopAnswer()
      else if (root.hasAnswer) { root.resetConversation(); root.setQuery("") }
      else if (root.query) root.setQuery("")
      else root.dismiss()
      return true
    }
    if (root.hasAnswer) {
      if (enter) { root.ask(root.query); return true }
      if (ctrl && event.key === Qt.Key_C && !input.selectedText) { root.copyAnswer(); return true }
      if (ctrl && event.key === Qt.Key_N) { root.resetConversation(); root.setQuery(""); return true }
      if (event.key === Qt.Key_PageUp) { answerView.flick(0, Style.space(1600)); return true }
      if (event.key === Qt.Key_PageDown) { answerView.flick(0, -Style.space(1600)); return true }
      return false
    }
    if (enter && ctrl) { root.ask(root.query); return true }
    if (enter) { root.activate(root.selectedIndex, alt); return true }
    if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) { root.move(1); return true }
    if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) { root.move(-1); return true }
    if (event.key === Qt.Key_Tab) { root.move(1); return true }
    if (event.key === Qt.Key_Backtab) { root.move(-1); return true }
    return false
  }

  property bool followAnswer: true

  // Rows appearing under a still pointer must not steal the selection.
  PointerMoveGate { id: pointerGate; referenceItem: results }

  // MARK: processes

  Timer {
    id: fileDebounce
    interval: 120
    onTriggered: root.startFileSearch()
  }

  Timer {
    id: flushTimer
    interval: 50
    onTriggered: root.flushLive()
  }

  Timer {
    id: noticeTimer
    interval: 1600
    onTriggered: root.notice = ""
  }

  Process {
    id: fileProc
    property string searched: ""
    stdout: StdioCollector {
      id: fileOut
      onStreamFinished: {
        var out = fileOut.text
        var nl = out.indexOf("\n")
        if (out.indexOf("q\t") !== 0 || nl < 0) return
        root.onFilesArrived(out.slice(2, nl), out.slice(nl + 1))
      }
    }
    onExited: Qt.callLater(function() {
      if (root.query.trim() !== fileProc.searched) root.startFileSearch()
    })
  }

  Process {
    id: askProc
    property bool streamed: false
    property string failed: ""
    property var pending: null
    stdout: SplitParser {
      onRead: function(data) { root.onStreamLine(data) }
    }
    stderr: StdioCollector { id: askErr }
    onExited: function(exitCode, exitStatus) { root.onAskExited(exitCode) }
  }

  // MARK: window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omalight"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height * 0.8)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(panel.height * 0.18)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: input.forceActiveFocus() }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // The input row: ghost, text, model.
        Item {
          width: parent.width
          height: root.inputHeight

          YinYang {
            id: mark
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 32
            height: 32
            color: root.accent
            opacity: root.answering ? 0.55 + 0.45 * pulse.value : 1

            QtObject { id: pulse; property real value: 1 }
            SequentialAnimation {
              running: root.answering
              loops: Animation.Infinite
              NumberAnimation { target: pulse; property: "value"; to: 0; duration: 600 }
              NumberAnimation { target: pulse; property: "value"; to: 1; duration: 600 }
              onRunningChanged: if (!running) pulse.value = 1
            }
          }

          TextInput {
            id: input
            anchors.left: mark.right
            anchors.leftMargin: Style.spacing.xl
            anchors.right: modelLabel.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            color: root.foreground
            selectionColor: root.selectedBackground
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading + Style.space(4)
            clip: true
            focus: true
            onTextEdited: root.setQuery(text)

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: !input.text
              text: root.hasAnswer ? root.tr(root.answering ? "answering" : "followUp") : root.tr("placeholder")
              color: root.foreground
              opacity: 0.45
              font: input.font
              elide: Text.ElideRight
            }
          }

          Text {
            id: modelLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.model.charAt(0).toUpperCase() + root.model.slice(1)
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Search results.
        ListView {
          id: results
          visible: !root.hasAnswer && root.rows.length > 0
          width: parent.width
          height: visible ? Math.min(root.rows.length, root.maxRows) * root.rowHeight : 0
          model: root.rows
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: rowItem
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex

            width: ListView.view.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: selected ? root.selectedBackground : "transparent"

            Item {
              id: iconSlot
              width: Style.font.display + Style.spacing.md
              height: parent.height
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md

              Image {
                anchors.centerIn: parent
                visible: rowItem.modelData.kind === "app"
                width: Style.font.display
                height: width
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                asynchronous: true
                source: rowItem.modelData.kind !== "app" ? ""
                  : rowItem.modelData.icon.charAt(0) === "/" ? Util.fileUrl(rowItem.modelData.icon)
                  : Quickshell.iconPath(rowItem.modelData.icon || "application-x-executable", "application-x-executable")
              }

              YinYang {
                anchors.centerIn: parent
                visible: rowItem.modelData.kind === "ask"
                width: 24
                height: 24
                color: root.accent
              }

              Text {
                anchors.centerIn: parent
                visible: rowItem.modelData.kind === "file"
                text: rowItem.modelData.dir ? "󰉋" : "󰈔"
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge + Style.space(2)
              }
            }

            Column {
              anchors.left: iconSlot.right
              anchors.leftMargin: Style.spacing.lg
              anchors.right: hint.left
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: rowItem.modelData.title
                color: rowItem.selected ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: rowItem.modelData.subtitle
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: rowItem.modelData.kind === "file" ? Text.ElideMiddle : Text.ElideRight
              }
            }

            Text {
              id: hint
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              visible: rowItem.selected
              text: root.tr(rowItem.modelData.kind === "ask" ? "hintAsk" : "hintOpen")
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                if (!pointerGate.moved(rowMouse, mouse)) return
                root.selectedIndex = rowItem.index
                root.userMoved = true
              }
              onClicked: root.activate(rowItem.index, false)
            }
          }
        }

        // The conversation.
        Flickable {
          id: answerView
          visible: root.hasAnswer
          width: parent.width
          height: visible ? Math.min(conversation.implicitHeight, panel.height * 0.8 - root.inputHeight - footer.height
                                     - Style.spacing.md * 3 - card.contentTopInset - card.contentBottomInset) : 0
          contentWidth: width
          contentHeight: conversation.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          function follow() {
            if (root.followAnswer && !answerView.moving) answerView.contentY = Math.max(0, answerView.contentHeight - answerView.height)
          }
          onContentHeightChanged: Qt.callLater(answerView.follow)
          onHeightChanged: Qt.callLater(answerView.follow)
          onMovementEnded: root.followAnswer = atYEnd

          Column {
            id: conversation
            width: answerView.width
            spacing: Style.spacing.xl

            Repeater {
              model: root.turns

              Column {
                id: turnItem
                required property var modelData
                required property int index
                width: conversation.width
                spacing: Style.spacing.md

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: turnItem.modelData.q
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.Wrap
                }

                Text {
                  id: answerText
                  readonly property bool live: root.answering && turnItem.index === root.turns.length - 1
                  readonly property string answer: live ? root.liveAnswer : turnItem.modelData.a
                  width: parent.width
                  visible: !!answer
                  textFormat: Text.MarkdownText
                  text: Search.safeMarkdown(answer)
                  color: root.foreground
                  linkColor: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  wrapMode: Text.Wrap
                  onLinkActivated: function(link) { if (Search.isWebLink(link)) root.run(["xdg-open", link]) }
                  onLinkHovered: function(link) { root.hoveredLink = link }
                }

                Text {
                  width: parent.width
                  visible: !answerText.answer && !turnItem.modelData.error
                  text: "…"
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  width: parent.width
                  visible: !!turnItem.modelData.error
                  textFormat: Text.PlainText
                  text: turnItem.modelData.error
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }

        // Keys for what is on screen.
        Text {
          id: footer
          width: parent.width
          visible: root.query.trim().length > 0 || root.hasAnswer
          textFormat: Text.PlainText
          text: root.hoveredLink ? (Search.isWebLink(root.hoveredLink) ? root.hoveredLink : root.tr("linkBlocked") + root.hoveredLink)
            : root.notice ? root.notice
            : root.tr(root.answering ? "footStop" : root.hasAnswer ? "footAnswer" : "footSearch")
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideLeft
        }
      }
    }
  }
}
