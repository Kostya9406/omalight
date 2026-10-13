import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search
import "Strings.js" as Strings

// OmaLight: a Spotlight-style bar for Omarchy, after Lumi (github.com/AlbertS15/Lumi).
// One input finds apps, open windows, Omarchy actions, keybindings and files,
// does sums, or asks Claude and streams the answer in place.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.kostya9406.omalight"
  readonly property string home: Quickshell.env("HOME")
  // Claude runs from here, so its sessions stay out of real projects; settings and launch counts live here too.
  readonly property string stateDir: root.home + "/.local/state/omalight"
  // A stand-in for omarchy-menu-select, so a keybinding row can run through
  // Omarchy's own omarchy-menu-keybindings, which knows how to dispatch Lua binds.
  readonly property string pickerDir: root.stateDir + "/picker"
  readonly property string filesScript: decodeURIComponent(Qt.resolvedUrl("files.sh").toString().replace(/^file:\/\//, ""))
  readonly property string openScript: decodeURIComponent(Qt.resolvedUrl("open.sh").toString().replace(/^file:\/\//, ""))
  readonly property string skillDir: root.omarchyPath + "/default/agents/skills/omarchy"

  // Models Ctrl+M cycles through; the aliases always resolve to the newest of each.
  readonly property var models: ["haiku", "sonnet", "opus"]
  property string model: "haiku"

  readonly property string systemPrompt:
    "You were called from OmaLight, a Spotlight-style quick bar on Omarchy Linux (Arch, Hyprland). " +
    "Answer briefly and to the point, in the language of the question. Start with the answer itself; " +
    "no filler, no restating the question, no offers of more help. " +
    "Use Markdown only for lists, bold and code. If you are unsure or need fresh facts, say so or search the web. " +
    "You cannot read or edit files or run commands here, so tell the user exactly what to run or change. " +
    "Omarchy reference documentation follows; trust it over general Hyprland knowledge (for example, " +
    "Omarchy keybindings live in ~/.config/hypr/bindings.lua)."

  property bool opened: false
  // "ru" or "en" from the summon payload or settings; otherwise the system locale decides.
  property string lang: ""
  readonly property bool ru: root.lang ? root.lang === "ru" : Strings.isRussian(Qt.locale().name)
  function tr(key) { return Strings.tr(key, root.ru) }
  property string query: ""

  // What search draws on, refreshed on every open.
  property var hiddenIds: ({})
  property var configuredHiddenIds: ({})
  property var usage: ({})
  property var menu: ({ items: {}, order: [] })
  property var menuHidden: ({})
  property var bindings: []
  property var clients: []
  property var limits: null

  // Search mode.
  property var files: []
  property string filesQuery: ""
  property var rows: []
  property int selectedIndex: 0
  property bool userMoved: false
  // An Enter that waits for the file search: the query, and whether Alt was held.
  property string pendingEnter: ""
  property bool pendingReveal: false

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

  Component.onCompleted: setupProc.running = true

  function open(payloadJson) {
    var changed = false
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && (payload.lang === "ru" || payload.lang === "en") && payload.lang !== root.lang) { root.lang = payload.lang; changed = true }
      if (payload && typeof payload.model === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(payload.model) && payload.model !== root.model) {
        root.model = payload.model
        changed = true
      }
    } catch (e) {
    }
    if (changed) root.saveSettings()
    root.resetConversation()
    root.setQuery("")
    root.opened = true
    root.refreshSources()
    Qt.callLater(function() { input.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopAnswer()
    fileDebounce.stop()
    root.hoveredLink = ""
    root.pendingEnter = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // Everything that can change between opens: open windows, keybindings,
  // menu conditions, apps hidden by the desktop.
  // Windows change all the time; the rest is slower to ask about (the menu
  // guards fork per condition), so it is asked again at most once a minute.
  property real slowRefreshedAt: 0
  function refreshSources() {
    if (!clientsProc.running) clientsProc.running = true
    if (Date.now() - root.slowRefreshedAt < 60000) return
    root.slowRefreshedAt = Date.now()
    if (!bindingsProc.running) bindingsProc.running = true
    if (!hiddenProc.running) hiddenProc.running = true
    root.runMenuGuards()
  }

  // Sources arrive after the bar is already open; show them without losing the
  // row the user picked.
  function sourcesChanged() {
    if (root.opened && !root.hasAnswer && root.query.trim()) root.rebuildRows()
  }

  function saveSettings() {
    settingsFile.setText(JSON.stringify({ model: root.model, lang: root.lang }) + "\n")
  }

  function cycleModel() {
    var i = root.models.indexOf(root.model)
    root.model = root.models[(i + 1) % root.models.length]
    root.saveSettings()
  }

  function noteUse(key) {
    root.usage = Search.recordUse(root.usage, key, Date.now())
    usageFile.setText(JSON.stringify(root.usage) + "\n")
  }

  // MARK: search

  function setQuery(text) {
    root.query = text
    if (input.text !== text) input.text = text
    if (root.hasAnswer) return
    root.userMoved = false
    root.pendingEnter = ""
    root.notice = ""
    root.rebuildRows()
    var q = text.trim()
    root.selectedIndex = Search.looksLikeQuestion(q) || root.rows.length < 2 ? 0 : 1
    // Pasted text with line breaks (an error message, say) is never a file name.
    if (q.length >= 2 && !root.multiline(q)) fileDebounce.restart()
    else { fileDebounce.stop(); root.files = []; root.filesQuery = "" }
  }

  function multiline(q) {
    return /[\r\n]/.test(q)
  }

  function rebuildRows() {
    var q = root.query.trim()
    if (!q) { root.rows = []; return }
    var hidden = {}
    for (var h in root.configuredHiddenIds) hidden[h] = true
    for (var h2 in root.hiddenIds) hidden[h2] = true
    var out = [{ kind: "ask", title: root.tr("ask"), subtitle: q }]

    var sum = Search.calculate(q)
    if (sum !== null) out.push({ kind: "calc", title: "= " + sum, subtitle: root.tr("calcSub"), value: String(sum) })

    // Apps, windows, Omarchy actions and keybindings rank together by how well
    // they match, so an exact "Theme" action beats an app that only mentions themes.
    // Actions and keybindings carry a small handicap, so "chrome" still opens the
    // app first rather than the "make Chrome the default browser" action.
    // On a tie the kinds keep this order.
    var ranked = []
    var handicap = [0, 0.5, 1.5, 1.5]
    function add(row, score, kindOrder) {
      ranked.push({ row: row, score: score + handicap[kindOrder], order: kindOrder, at: ranked.length })
    }

    var apps = Search.searchApps(DesktopEntries.applications.values || [], q, hidden, root.usage, Date.now())
    for (var i = 0; i < apps.length; i++) {
      var e = apps[i]
      add({ kind: "app", title: String(e.name || e.id), subtitle: String(e.genericName || e.comment || root.tr("app")),
            icon: String(e.icon || ""), id: String(e.id || "") }, Search.appScore(e, q), 0)
    }

    var wins = Search.searchWindows(root.clients, q, 3)
    for (var w = 0; w < wins.length; w++) {
      var c = wins[w]
      var ws = c.workspace && c.workspace.name ? " · " + root.tr("workspace") + c.workspace.name : ""
      add({ kind: "window", title: String(c.title || c["class"]), subtitle: root.tr("window") + " · " + String(c["class"] || "") + ws,
            address: String(c.address), icon: String(c["class"] || "").toLowerCase() },
          Math.min(Search.rowScore(c["class"], "", q), Search.rowScore(c.title, "", q)), 1)
    }

    var actions = Search.searchMenu(root.menu, root.menuHidden, q, 5, root.usage, Date.now())
    for (var a = 0; a < actions.length; a++) {
      var m = actions[a]
      var where = ["Omarchy"].concat(m.path).join(" › ")
      add({ kind: "action", title: m.label, subtitle: where + (m.description ? " · " + m.description : ""),
            glyph: m.icon, id: m.id, action: m.action, route: m.route }, m.score, 2)
    }

    var binds = Search.searchBindings(root.bindings, q, 3)
    for (var b = 0; b < binds.length; b++)
      add({ kind: "binding", title: binds[b].desc, subtitle: root.tr("binding") + " · " + binds[b].keys, line: binds[b].line },
          Search.rowScore(binds[b].desc, binds[b].keys, q), 3)

    ranked.sort(function(x, y) { return x.score - y.score || x.order - y.order || x.at - y.at })
    for (var r = 0; r < ranked.length; r++) out.push(ranked[r].row)

    if (root.filesQuery === q) {
      for (var j = 0; j < root.files.length; j++) {
        var f = root.files[j]
        out.push({ kind: "file", title: Search.baseName(f.path), subtitle: Search.tildify(Search.dirName(f.path), root.home),
                   path: f.path, dir: f.dir })
      }
    }
    var picked = root.userMoved ? root.rows[root.selectedIndex] : null
    root.rows = out
    pointerGate.reset()
    if (picked) {
      for (var k = 0; k < out.length; k++) {
        if (out[k].kind === picked.kind && out[k].title === picked.title && out[k].subtitle === picked.subtitle) { root.selectedIndex = k; break }
      }
    }
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
  }

  function onFilesArrived(q, output) {
    root.files = Search.filterFiles(output, root.home, q)
    root.filesQuery = q
    if (root.hasAnswer || q !== root.query.trim()) return
    root.rebuildRows()
    if (!root.userMoved) {
      // A file or app named exactly what was typed wins, even when the text reads
      // like a question ("my notes for monday.txt"); otherwise a search lands on
      // the first result and a question stays on the ask row.
      var exact = root.exactMatchRow(q)
      if (exact > 0) root.selectedIndex = exact
      else if (!Search.looksLikeQuestion(q) && root.selectedIndex === 0 && root.rows.length > 1) root.selectedIndex = 1
    }
    if (root.pendingEnter === q) {
      root.pendingEnter = ""
      root.notice = ""
      var row = root.rows[root.selectedIndex]
      if (row && row.kind === "ask" && !Search.looksLikeQuestion(q)) {
        // A search-like query is never sent to Claude by an Enter pressed before
        // anyone saw the results: with results on screen the choice is left to
        // the user; with none, the same notice as in enter().
        if (root.rows.length < 2) root.sayNothingFound()
        return
      }
      root.activate(root.selectedIndex, root.pendingReveal)
    }
  }

  // The next Enter asks Claude: the ask row, alone on screen, now counts as chosen.
  // The notice stays until the text changes.
  function sayNothingFound() {
    root.userMoved = true
    noticeTimer.stop()
    root.notice = root.tr("nothingFound")
  }

  function onFilesFailed(q) {
    if (root.pendingEnter !== q) return
    root.pendingEnter = ""
    root.notice = root.tr("filesTimeout")
    noticeTimer.restart()
  }

  function exactMatchRow(q) {
    var want = q.toLowerCase()
    for (var i = 1; i < root.rows.length; i++) {
      var r = root.rows[i]
      if (r.kind !== "file" && r.kind !== "app") continue
      var t = String(r.title).toLowerCase()
      if (t === want || t.replace(/\.[^.]+$/, "") === want) return i
    }
    return -1
  }

  // Plain Enter on the ask row nobody picked waits for the file search of this
  // query (usually well under a second), so typing a file name and pressing
  // Enter quickly opens the file instead of sending its name to Claude.
  function enter(reveal) {
    var q = root.query.trim()
    var row = root.rows[root.selectedIndex]
    if (row && row.kind === "ask" && !root.userMoved && !root.multiline(q)) {
      if (q.length >= 2 && root.filesQuery !== q) {
        root.pendingEnter = q
        root.pendingReveal = reveal
        root.notice = root.tr("searchingFiles")
        // After a failed search nothing else would search this query again.
        if (!fileProc.running && !fileDebounce.running) root.startFileSearch()
        return
      }
      // The search already came back empty: same answer as when Enter waited
      // for it, so how fast plocate was never decides what reaches Claude.
      if (!Search.looksLikeQuestion(q) && root.rows.length < 2) {
        root.sayNothingFound()
        return
      }
    }
    root.activate(root.selectedIndex, reveal)
  }

  function startFileSearch() {
    var q = root.query.trim()
    if (q.length < 2 || root.hasAnswer || root.multiline(q)) return
    if (fileProc.running) return // onExited picks the newest query up
    fileProc.searched = q
    // files.sh: plocate's index plus fd for what changed since it was built.
    // timeout kills the whole process group (bash, fd, plocate) of a search that hangs.
    fileProc.command = ["timeout", "-k", "1", "4", "bash", root.filesScript, q]
    fileProc.running = true
    fileWatchdog.restart()
  }

  function runMenuGuards() {
    var script = Search.menuGuardScript(root.menu)
    if (!script) return
    // A run for an older menu finishes first; then this one goes again.
    if (guardProc.running) { guardProc.again = true; return }
    guardProc.again = false
    guardProc.forMenu = root.menu
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
    guardTimeout.restart()
  }

  function loadMenu() {
    root.menu = Search.parseMenu(defaultMenuFile.text(), userMenuFile.text())
    root.runMenuGuards()
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
    if (row.kind === "ask") { if (!reveal) root.ask(row.subtitle); return }
    if (row.kind === "file") {
      // open.sh rather than xdg-open: it also opens files whose app runs in a terminal (nvim for text).
      root.run(["uwsm-app", "--", "bash", root.openScript, reveal && !row.dir ? Search.dirName(row.path) : row.path, root.tr("noOpener")])
      root.dismiss()
      return
    }
    if (reveal) return
    if (row.kind === "calc") {
      Quickshell.clipboardText = row.value
      root.dismiss()
    } else if (row.kind === "app") {
      root.noteUse("app:" + row.id)
      root.dismiss()
      root.beginLaunchFeedback(row.title)
      root.run(["uwsm-app", "--", "gtk-launch", row.id + ".desktop"])
    } else if (row.kind === "window") {
      root.dismiss()
      // The address passed /^0x[0-9a-f]+$/ in Search.searchWindows, and still only reaches bash as "$1".
      root.run(["bash", "-c",
        // Lua dispatch counts as done only on status 0 with empty or "ok" output, as in omarchy-menu-keybindings.
        'out=$(hyprctl dispatch "hl.dsp.focus({ window = \\"address:$1\\" })" 2>&1) && { [ -z "$out" ] || [ "$out" = ok ]; } || hyprctl dispatch focuswindow "address:$1"',
        "bash", row.address])
    } else if (row.kind === "action") {
      root.noteUse("menu:" + row.id)
      root.dismiss()
      // Menu actions are the user's and Omarchy's own commands; run them the way the Omarchy menu does.
      if (row.action) Quickshell.execDetached(["bash", "-lc", row.action])
      else root.run(["omarchy-menu", "summon", row.route])
    } else if (row.kind === "binding") {
      root.dismiss()
      // Give focus back to the window the binding acts on, then let Omarchy dispatch it.
      root.run(["bash", "-c", 'sleep 0.15; PATH="$1:$PATH" OMALIGHT_PICK="$2" exec omarchy-menu-keybindings',
                "bash", root.pickerDir, row.line])
    }
  }

  // argv only ever lands in bash's positional parameters, so nothing typed is re-parsed.
  function run(argv) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  // MARK: launch feedback (as the Omarchy menu does it)

  property int launchToplevels: 0
  property var launchActive: null
  property string launchName: ""
  property bool launchOsdOpen: false

  function toplevelCount() {
    try { return ToplevelManager.toplevels.values.length } catch (e) { return 0 }
  }

  function beginLaunchFeedback(name) {
    root.launchToplevels = root.toplevelCount()
    root.launchActive = ToplevelManager.activeToplevel
    root.launchName = name
    launchDelay.restart()
    launchTimeout.restart()
  }

  function endLaunchFeedback() {
    launchDelay.stop()
    launchTimeout.stop()
    if (root.launchOsdOpen) Quickshell.execDetached(["omarchy-shell", "osd", "close"])
    root.launchOsdOpen = false
  }

  function checkLaunched() {
    if (!launchDelay.running && !launchTimeout.running) return
    if (root.toplevelCount() <= root.launchToplevels && ToplevelManager.activeToplevel === root.launchActive) return
    root.endLaunchFeedback()
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.checkLaunched() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.checkLaunched() }
  }

  // As in the Omarchy menu: only a launch still without a window after two
  // seconds gets the notice, so fast apps never flash it.
  Timer {
    id: launchDelay
    interval: 2000
    onTriggered: {
      if (root.toplevelCount() > root.launchToplevels || ToplevelManager.activeToplevel !== root.launchActive) {
        launchTimeout.stop()
        return
      }
      root.launchOsdOpen = true
      Quickshell.execDetached(["omarchy-shell", "osd", "show",
        JSON.stringify({ icon: "󱓞", message: root.tr("launching") + root.launchName + "…", duration: 0 })])
    }
  }

  Timer {
    id: launchTimeout
    interval: 15000
    onTriggered: root.endLaunchFeedback()
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
                "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"]
    if (root.sessionId) args.push("--resume", root.sessionId)
    var command = ["bash", "-lc",
      // The question goes in on stdin, never through a shell; exec so stopping the run stops claude.
      // Omarchy's own agent guide joins the system prompt, so answers fit this system.
      'd=$1; q=$2; p=$3; k=$4; shift 4; mkdir -p "$d" && cd "$d" || exit 1; ' +
      'for f in SKILL.md hyprland.md theming.md plugins.md; do [ -f "$k/$f" ] && p+=$\'\\n\\n\'"$(cat "$k/$f")"; done; ' +
      'exec claude "$@" --append-system-prompt "$p" <<<"$q"',
      "bash", root.stateDir, q, root.systemPrompt, root.skillDir].concat(args)
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
    root.hoveredLink = ""
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
    if (ctrl && event.key === Qt.Key_M) { root.cycleModel(); return true }
    if (root.hasAnswer) {
      if (enter) { root.ask(root.query); return true }
      // Ctrl+Insert too: Omarchy's Super+C sends it instead of Ctrl+C when a terminal is the active window.
      if (ctrl && (event.key === Qt.Key_C || event.key === Qt.Key_Insert) && !input.selectedText) { root.copyAnswer(); return true }
      if (ctrl && event.key === Qt.Key_N) { root.resetConversation(); root.setQuery(""); return true }
      if (event.key === Qt.Key_PageUp) { answerView.flick(0, Style.space(1600)); return true }
      if (event.key === Qt.Key_PageDown) { answerView.flick(0, -Style.space(1600)); return true }
      return false
    }
    if (enter && ctrl) { root.ask(root.query); return true }
    if (enter) { root.enter(alt); return true }
    if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) { root.move(1); return true }
    if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) { root.move(-1); return true }
    if (event.key === Qt.Key_Tab) { root.move(1); return true }
    if (event.key === Qt.Key_Backtab) { root.move(-1); return true }
    return false
  }

  property bool followAnswer: true

  // Rows appearing under a still pointer must not steal the selection.
  PointerMoveGate { id: pointerGate; referenceItem: results }

  // MARK: state files

  // Creates the state folder and the picker stand-in: it drains the list it is
  // given and answers with the line OmaLight already chose.
  Process {
    id: setupProc
    command: ["bash", "-c",
      'mkdir -p "$1" && printf "%s\\n" "#!/bin/sh" "cat >/dev/null" "printf \'%s\\\\n\' \\"\\$OMALIGHT_PICK\\"" > "$1/omarchy-menu-select" && chmod 755 "$1/omarchy-menu-select"',
      "bash", root.pickerDir]
    onExited: {
      settingsFile.reload()
      usageFile.reload()
    }
  }

  FileView {
    id: settingsFile
    path: root.stateDir + "/settings.json"
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (typeof s.model === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s.model)) root.model = s.model
        if (s.lang === "ru" || s.lang === "en" || s.lang === "") root.lang = s.lang
      } catch (e) {
      }
    }
  }

  FileView {
    id: usageFile
    path: root.stateDir + "/usage.json"
    printErrors: false
    onLoaded: {
      try {
        var u = JSON.parse(text())
        if (u && typeof u === "object" && !Array.isArray(u)) root.usage = u
      } catch (e) {
      }
    }
  }

  // MARK: Omarchy sources

  FileView {
    id: defaultMenuFile
    path: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMenu()
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.home + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMenu()
    onFileChanged: reload()
    onLoadFailed: root.loadMenu()
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.configuredHiddenIds = Search.parseHiddenIds(text())
    onFileChanged: reload()
  }

  FileView {
    path: root.home + "/.local/state/omarchy/agents/usage/claude.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.limits = Search.claudeUsage(text())
    onFileChanged: reload()
  }

  Process {
    id: hiddenProc
    command: ["bash", "-c", 's="$1/shell/services/hidden-entries.sh"; [ -x "$s" ] && exec "$s" "$2"', "bash", root.omarchyPath,
      [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")]
        .filter(function(v) { return String(v || "").length > 0 }).join(":")]
    stdout: StdioCollector {
      id: hiddenOut
      onStreamFinished: { root.hiddenIds = Search.parseHiddenIds(hiddenOut.text); root.sourcesChanged() }
    }
  }

  Process {
    id: guardProc
    property var forMenu: null
    property bool again: false
    stdout: StdioCollector {
      id: guardOut
      onStreamFinished: {
        if (guardProc.forMenu !== root.menu) return
        root.menuHidden = Search.parseGuardOutput(root.menu, guardOut.text)
        root.sourcesChanged()
      }
    }
    onExited: {
      guardTimeout.stop()
      if (guardProc.again || guardProc.forMenu !== root.menu) Qt.callLater(root.runMenuGuards)
    }
  }

  // A `when:` that hangs must not leave the guards running for good.
  Timer {
    id: guardTimeout
    interval: 5000
    onTriggered: guardProc.running = false
  }

  Process {
    id: bindingsProc
    command: ["bash", "-c", "omarchy-menu-keybindings --print 2>/dev/null"]
    stdout: StdioCollector {
      id: bindingsOut
      onStreamFinished: { root.bindings = Search.parseKeybindings(bindingsOut.text); root.sourcesChanged() }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      id: clientsOut
      onStreamFinished: {
        try { root.clients = JSON.parse(clientsOut.text) } catch (e) { root.clients = [] }
        root.sourcesChanged()
      }
    }
  }

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
        if (out.indexOf("q\t") !== 0 || nl < 0) { root.onFilesFailed(fileProc.searched); return }
        // Without the closing "end" the search was cut short: never act on it.
        if (!/(^|\n)end\n?$/.test(out)) { root.onFilesFailed(out.slice(2, nl)); return }
        root.onFilesArrived(out.slice(2, nl), out.slice(nl + 1))
      }
    }
    onExited: {
      fileWatchdog.stop()
      Qt.callLater(function() {
        if (root.query.trim() !== fileProc.searched) root.startFileSearch()
      })
    }
  }

  // A search that hangs (a stuck disk) is stopped, so the next one can run; an
  // Enter that was waiting on it is dropped rather than sent to Claude.
  Timer {
    id: fileWatchdog
    interval: 6000
    onTriggered: {
      fileProc.running = false
      if (root.pendingEnter) {
        root.pendingEnter = ""
        root.notice = root.tr("filesTimeout")
        noticeTimer.restart()
      }
    }
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

        // The input row: mark, text, model and Claude's session limit.
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
            textFormat: Text.PlainText
            text: root.model.charAt(0).toUpperCase() + root.model.slice(1)
              + (root.limits && root.limits.session ? " · " + root.tr("limitShort") + root.limits.session.percent + "%" : "")
            color: modelMouse.containsMouse ? root.accent : root.foreground
            opacity: modelMouse.containsMouse ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall

            MouseArea {
              id: modelMouse
              anchors.fill: parent
              anchors.margins: -Style.spacing.md
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.cycleModel(); input.forceActiveFocus() }
              onContainsMouseChanged: root.notice = containsMouse ? root.tr("modelHint") : ""
            }
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
            readonly property string kind: modelData.kind

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
                id: appIcon
                anchors.centerIn: parent
                visible: (rowItem.kind === "app" || rowItem.kind === "window") && status === Image.Ready
                width: Style.font.display
                height: width
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                asynchronous: true
                source: rowItem.kind === "app"
                  ? (rowItem.modelData.icon.charAt(0) === "/" ? Util.fileUrl(rowItem.modelData.icon)
                     : Quickshell.iconPath(rowItem.modelData.icon || "application-x-executable", "application-x-executable"))
                  : rowItem.kind === "window" ? Quickshell.iconPath(rowItem.modelData.icon, true) : ""
              }

              YinYang {
                anchors.centerIn: parent
                visible: rowItem.kind === "ask"
                width: 24
                height: 24
                color: root.accent
              }

              Text {
                anchors.centerIn: parent
                visible: !appIcon.visible && rowItem.kind !== "ask"
                textFormat: Text.PlainText
                text: rowItem.kind === "file" ? (rowItem.modelData.dir ? "󰉋" : "󰈔")
                  : rowItem.kind === "calc" ? "󰃬"
                  : rowItem.kind === "window" ? "󰖯"
                  : rowItem.kind === "binding" ? "󰌌"
                  : rowItem.kind === "action" ? (rowItem.modelData.glyph || "󱓞")
                  : "󰣆"
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
                elide: rowItem.kind === "file" ? Text.ElideMiddle : Text.ElideRight
              }
            }

            Text {
              id: hint
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              visible: rowItem.selected
              textFormat: Text.PlainText
              text: root.tr(rowItem.kind === "ask" ? "hintAsk" : rowItem.kind === "calc" ? "hintCopy"
                : rowItem.kind === "window" ? "hintSwitch"
                : rowItem.kind === "action" || rowItem.kind === "binding" ? "hintRun" : "hintOpen")
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
                  // No HTML of OmaLight's own goes into the answer (not even to colour links,
                  // which Markdown leaves at Qt's default): see Search.safeMarkdown.
                  text: Search.safeMarkdown(answer)
                  color: root.foreground
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
          visible: root.query.trim().length > 0 || root.hasAnswer || !!root.notice
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
