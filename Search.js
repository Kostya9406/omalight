// Pure logic for the OmaLight overlay: what counts as a question, how apps and
// files rank, and how a line of `claude -p --output-format stream-json` reads.
// Kept free of QML so it can be tested with node (see tests/).

// First words that make the typed text a question rather than a search,
// taken from Lumi (github.com/AlbertS15/Lumi, windows/Lumi/Strings.cs).
var QUESTION_WORDS = [
  "what", "how", "why", "when", "where", "who", "which", "explain", "write", "translate",
  "can", "is", "are", "should", "does", "do",
  "что", "как", "почему", "зачем", "когда", "где", "кто", "сколько", "какой", "какая",
  "какие", "какое", "можно", "объясни", "напиши", "переведи", "посчитай", "расскажи",
  "придумай", "сравни", "чем"
]

// Files under these never show: caches, trash, dependency trees, VCS internals.
var BLOCKED = ["/.cache/", "/.local/share/Trash/", "/node_modules/", "/.git/", "/.npm/", "/.cargo/"]

var MAX_APPS = 6
var MAX_FILES = 8

function looksLikeQuestion(text) {
  var t = String(text || "").trim().toLowerCase()
  if (!t) return false
  if (t.charAt(t.length - 1) === "?") return true
  var words = t.split(/\s+/)
  if (words.length >= 4) return true
  return QUESTION_WORDS.indexOf(words[0]) >= 0
}

function keywordText(entry) {
  try {
    if (entry && entry.keywords && typeof entry.keywords.join === "function") return entry.keywords.join(" ")
  } catch (e) {
  }
  return ""
}

// Lower is better; -1 means no match. Name prefix beats a word start in the
// name, which beats anywhere in the name, which beats generic name / keywords.
function appScore(entry, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q || !entry) return -1
  var name = String(entry.name || "").toLowerCase()
  if (name.indexOf(q) === 0) return 0
  var at = name.indexOf(q)
  if (at > 0 && /[\s\-_.]/.test(name.charAt(at - 1))) return 1
  if (at > 0) return 2
  var extra = [entry.genericName, entry.comment, keywordText(entry), entry.id].join(" ").toLowerCase()
  if (extra.indexOf(q) >= 0) return 3
  return -1
}

// Apps matching the query, minus hidden ones; within the same match quality the
// more often and recently launched app comes first.
function searchApps(entries, query, hidden, usage, now) {
  var scored = []
  var seen = {}
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (!e || e.noDisplay) continue
    // Compared as is, like the Omarchy app library: only the hide lists drop ".desktop".
    var id = String(e.id || "")
    if (hidden && hidden[id]) continue
    var score = appScore(e, query)
    if (score < 0) continue
    var key = id || String(e.name)
    if (seen[key]) continue
    seen[key] = true
    // The raw id, as OmaLight.qml records launches ("org.telegram.desktop" keeps its suffix).
    scored.push({ score: score, entry: e, used: frecency(usage, "app:" + String(e.id || ""), now) })
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
    if (a.used !== b.used) return b.used - a.used
    return String(a.entry.name).localeCompare(String(b.entry.name))
  })
  return scored.slice(0, MAX_APPS).map(function(s) { return s.entry })
}

// Lines of "<d|f>\t<path>" (see the file search in Lumi.qml) → [{ path, dir }]
// worth showing: inside home, no hidden folders on the way, nothing blocked.
// Exact-name hits first, then names starting with the query, then shorter paths.
function filterFiles(output, home, query) {
  var prefix = String(home || "") + "/"
  var q = String(query || "").trim().toLowerCase()
  var lines = String(output || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tab = line.indexOf("\t")
    if (tab !== 1) continue
    var path = line.slice(2)
    if (!path || path.indexOf(prefix) !== 0) continue
    if (path.slice(prefix.length).indexOf("/.") >= 0 || path.charAt(prefix.length) === ".") continue
    var blocked = false
    for (var b = 0; b < BLOCKED.length; b++) {
      if (path.indexOf(BLOCKED[b]) >= 0) { blocked = true; break }
    }
    if (!blocked) out.push({ path: path, dir: line.charAt(0) === "d" })
  }
  out.sort(function(a, b) {
    var na = baseName(a.path).toLowerCase(), nb = baseName(b.path).toLowerCase()
    var ra = na === q ? 0 : na.indexOf(q) === 0 ? 1 : 2
    var rb = nb === q ? 0 : nb.indexOf(q) === 0 ? 1 : 2
    if (ra !== rb) return ra - rb
    return a.path.length - b.path.length
  })
  return out.slice(0, MAX_FILES)
}

function baseName(path) {
  var s = String(path || "")
  return s.slice(s.lastIndexOf("/") + 1)
}

function dirName(path) {
  var s = String(path || "")
  var i = s.lastIndexOf("/")
  return i > 0 ? s.slice(0, i) : "/"
}

function tildify(path, home) {
  var s = String(path || "")
  return home && s.indexOf(home) === 0 ? "~" + s.slice(home.length) : s
}

// One line of stream-json → { kind, ... } or null for lines that do not matter.
//   { kind: "session", id }      the session to --resume for a follow-up
//   { kind: "text", text }       a streamed piece of the answer
//   { kind: "full", text }       the whole assistant turn (used when nothing streamed)
//   { kind: "error", text }      the run failed
//   { kind: "done" }             the run finished fine
function parseStreamLine(line) {
  var o
  try { o = JSON.parse(line) } catch (e) { return null }
  if (!o || typeof o !== "object") return null
  if (o.type === "system" && o.subtype === "init" && o.session_id) return { kind: "session", id: String(o.session_id) }
  if (o.type === "stream_event" && o.event && o.event.delta && o.event.delta.type === "text_delta")
    return { kind: "text", text: String(o.event.delta.text || "") }
  if (o.type === "assistant" && o.message && Array.isArray(o.message.content)) {
    var text = ""
    for (var i = 0; i < o.message.content.length; i++) {
      var c = o.message.content[i]
      if (c && c.type === "text") text += String(c.text || "")
    }
    if (o.error) return { kind: "error", text: text || String(o.error) }
    return { kind: "full", text: text }
  }
  if (o.type === "result") {
    if (o.is_error) return { kind: "error", text: String(o.result || "") }
    return { kind: "done" }
  }
  return null
}

// Applies `fn` to the Markdown outside code: fenced blocks (closed or still
// streaming) and inline code spans pass through untouched. This guess at what
// is code can differ from Qt's own Markdown parser, so it is only used for a
// cosmetic change (autolinks), never for safety.
function outsideCode(text, fn) {
  var parts = String(text || "").split(/(```[\s\S]*?(?:```|$)|`[^`\n]*`)/)
  for (var i = 0; i < parts.length; i += 2) parts[i] = fn(parts[i])
  return parts.join("")
}

function linkAddress(url) {
  return url.replace(/\(/g, "%28").replace(/\)/g, "%29").replace(/\[/g, "%5B").replace(/\]/g, "%5D")
}

// U+2060 WORD JOINER: invisible, zero width, and not Markdown or HTML syntax.
var WJ = "\u2060"

// Model output is untrusted (web pages it read can steer it). Qt's Markdown
// renderer fetches images on its own, so an image could carry the conversation
// out in its URL without a click, and raw HTML could do the same with <img>.
// So, everywhere in the text, code included, since nothing here can tell code
// apart exactly as Qt does: "![" never stays together (any image form, nested,
// reference or shortcut, becomes "!" before an ordinary link), and every "<"
// is followed by the word joiner, so no tag, comment or declaration can start,
// not even one Qt would assemble after stripping emphasis or decoding entities
// ("<*img", "<&#105;mg"). The text is never given any HTML of OmaLight's own
// either: Qt only parses raw HTML once some tag opens it, and none can.
// The word joiner is invisible, so code and placeholders such as <name> read
// as before; copying an answer takes the original text, not this.
function safeMarkdown(text) {
  return outsideCode(text, function(md) {
    // Autolinks and <url> link destinations look like tags; turn them into
    // ordinary links first. Brackets and parentheses are escaped in the label
    // and percent-encoded in the address, so they cannot end the link early.
    return md
      .replace(/\]\(<(https?:\/\/[^\s<>]+)>\)/gi, function(all, url) { return "](" + linkAddress(url) + ")" })
      .replace(/<(https?:\/\/[^\s<>]+)>/gi, function(all, url) {
        return "[" + url.replace(/[\[\]\\]/g, "\\$&") + "](" + linkAddress(url) + ")"
      })
  })
    .replace(/!\[/g, "!" + WJ + "[")
    .replace(/</g, "<" + WJ)
}

// Only plain web links open from an answer; file:, custom schemes and relative
// links could launch something local.
function isWebLink(link) {
  return /^https?:\/\/[^\s]+$/i.test(String(link || ""))
}

// The errors people actually hit → a Strings.js key, plus the raw text where it helps.
function explainError(text) {
  var t = String(text || "")
  if (/authenticat|log ?in|credential|oauth/i.test(t)) return { key: "errAuth", detail: "" }
  if (/rate.?limit|usage limit|quota/i.test(t)) return { key: "errLimit", detail: t }
  if (/command not found|No such file/i.test(t)) return { key: "errMissing", detail: "" }
  return t ? { key: "", detail: t } : { key: "errFailed", detail: "" }
}

// MARK: shared scoring

// Lower is better; -1 means no match. Prefix of the name, then a word start in
// it, then anywhere in it, then anywhere in the extra text.
function textScore(name, extra, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return -1
  var n = String(name || "").toLowerCase()
  if (n.indexOf(q) === 0) return 0
  var at = n.indexOf(q)
  if (at > 0 && /[\s\-_.›/]/.test(n.charAt(at - 1))) return 1
  if (at > 0) return 2
  if (String(extra || "").toLowerCase().indexOf(q) >= 0) return 3
  return -1
}

function topScored(list, scoreOf, limit, tieBreak) {
  var scored = []
  for (var i = 0; i < list.length; i++) {
    var score = scoreOf(list[i])
    if (score >= 0) scored.push({ score: score, item: list[i], at: i })
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
    var t = tieBreak ? tieBreak(a.item, b.item) : 0
    return t !== 0 ? t : a.at - b.at
  })
  return scored.slice(0, limit).map(function(s) { return s.item })
}

// The match quality of a result row, for ranking rows of different kinds together.
function rowScore(name, extra, query) {
  var s = textScore(name, extra, query)
  return s < 0 ? 9 : s
}

// MARK: hidden apps

// launcher.hides and hidden-entries.sh output: one desktop id per line, ".desktop" optional.
function parseHiddenIds(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var id = lines[i].trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    if (id && id.charAt(0) !== "#") out[id] = true
  }
  return out
}

// MARK: frecency

// usage: { "<key>": { count, last } } with `last` in ms. Recent and frequent wins;
// a launch counts half as much after a week.
function frecency(usage, key, now) {
  var u = usage && usage[key]
  if (!u || !u.count) return 0
  var days = Math.max(0, ((now || Date.now()) - (u.last || 0)) / 86400000)
  return u.count / (1 + days / 7)
}

function recordUse(usage, key, now) {
  var next = {}
  for (var k in usage || {}) next[k] = usage[k]
  var prior = next[key] || { count: 0, last: 0 }
  next[key] = { count: Math.min(prior.count + 1, 1000), last: now || Date.now() }
  // Keep the file small: drop the least used keys beyond 300.
  var keys = Object.keys(next)
  if (keys.length > 300) {
    keys.sort(function(a, b) { return frecency(next, a, now) - frecency(next, b, now) })
    for (var i = 0; i < keys.length - 300; i++) delete next[keys[i]]
  }
  return next
}

// MARK: Omarchy menu

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function parseJsoncObject(raw) {
  try {
    var parsed = JSON.parse(stripJsonc(raw))
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
      return parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items) ? parsed.items : parsed
  } catch (e) {
  }
  return {}
}

// The default menu and the user's extension, merged the way the Omarchy menu
// merges them: the same id extends or overrides the default entry.
function parseMenu(defaultRaw, userRaw) {
  var items = {}
  var order = []
  var sources = [parseJsoncObject(defaultRaw), parseJsoncObject(userRaw)]
  for (var s = 0; s < sources.length; s++) {
    for (var id in sources[s]) {
      var v = sources[s][id]
      if (!v || typeof v !== "object" || Array.isArray(v)) continue
      if (!items[id]) { items[id] = { id: id }; order.push(id) }
      for (var k in v) items[id][k] = v[k]
    }
  }
  for (var i = 0; i < order.length; i++) {
    var e = items[order[i]]
    if (e.parent === undefined) e.parent = e.id.indexOf(".") >= 0 ? e.id.split(".").slice(0, -1).join(".") : "root"
    e.label = String(e.label || e.id)
  }
  return { items: items, order: order }
}

function menuPath(items, id) {
  var parts = []
  var guard = 0
  var cur = items[id]
  while (cur && cur.parent && cur.parent !== "root" && guard++ < 16) {
    cur = items[cur.parent]
    if (cur) parts.unshift(cur.label)
  }
  return parts
}

// Package and command checks are most of what `when:` asks, and asked one
// pacman call at a time they take seconds. As the Omarchy menu does, the batch
// answers them in-process: one `pacman -Qq`/`-Qi` read (provides included),
// and shadow functions for omarchy-pkg-present/-missing and
// omarchy-cmd-present/-missing that agree with the real commands. A version
// constraint (`bash>=1`) still goes to pacman. The readers below run once and
// their output stands in for `$(reader)` in the guards.
// Adapted from Omarchy's shell/plugins/menu/MenuModel.js (MIT).
var GUARD_READERS = [
  "omarchy-channel-current",
  "omarchy-default-agent",
  "omarchy-default-browser",
  "omarchy-default-editor",
  "omarchy-default-terminal",
  "omarchy-dns"
]

function guardHelpers() {
  return 'declare -A __omarchy_pkgs=()\n'
    + 'mapfile -t __omarchy_pkg_names < <({ pacman -Qq; LC_ALL=C pacman -Qi'
    + " | awk '/^[A-Za-z]/ { provides = ($0 ~ /^Provides/); sub(/^[^:]*: /, \"\") }"
    + ' provides && $0 != "None" { n = split($0, p, " ");'
    + ' for (i = 1; i <= n; i++) { sub(/[<>=].*/, "", p[i]); print p[i] } }\'; } 2>/dev/null)\n'
    + 'for __omarchy_pkg in "${__omarchy_pkg_names[@]}"; do __omarchy_pkgs[$__omarchy_pkg]=1; done\n'
    + '__omarchy_pkg_has() { [[ -n ${__omarchy_pkgs[$1]-} ]] && return 0; '
    + '[[ $1 == *[\\<\\>=]* ]] && { pacman -Q "$1" &>/dev/null; return; }; return 1; }\n'
    + 'omarchy-pkg-present() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 1; done; return 0; }\n'
    + 'omarchy-pkg-missing() { local p; for p in "$@"; do __omarchy_pkg_has "$p" || return 0; done; return 1; }\n'
    + 'omarchy-cmd-present() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 1; done; return 0; }\n'
    + 'omarchy-cmd-missing() { local c; for c in "$@"; do command -v "$c" &>/dev/null || return 0; done; return 1; }\n'
}

function guardReaderSlot(index) {
  return "${__omarchy_read_" + index + "}"
}

function substituteGuardReaders(expression) {
  for (var i = 0; i < GUARD_READERS.length; i++)
    expression = expression.split("$(" + GUARD_READERS[i] + ")").join(guardReaderSlot(i))
  return expression
}

// One bash script answering every `when:` as "<index>:<0|1>" lines. Ids are
// never put in the script, only their index, so an id cannot break out of it.
function menuGuardScript(menu) {
  var lines = []
  for (var i = 0; i < menu.order.length; i++) {
    var e = menu.items[menu.order[i]]
    if (e && typeof e.when === "string" && e.when)
      lines.push("if { " + substituteGuardReaders(e.when) + "; } >/dev/null 2>&1 </dev/null; then echo " + i + ":1; else echo " + i + ":0; fi")
  }
  if (lines.length === 0) return ""
  var body = lines.join("\n")
  var prelude = guardHelpers()
  for (var r = 0; r < GUARD_READERS.length; r++) {
    // `|| :` so a reader that exits nonzero cannot stop the batch.
    if (body.indexOf(guardReaderSlot(r)) >= 0)
      prelude += "__omarchy_read_" + r + "=$(" + GUARD_READERS[r] + " 2>/dev/null) || :\n"
  }
  return prelude + body
}

function parseGuardOutput(menu, text) {
  var hidden = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^(\d+):0$/.exec(lines[i].trim())
    if (m && menu.order[+m[1]]) hidden[menu.order[+m[1]]] = true
  }
  return hidden
}

function menuHiddenUpwards(menu, hidden, id) {
  var guard = 0
  var cur = menu.items[id]
  while (cur && guard++ < 16) {
    if (hidden[cur.id]) return true
    cur = cur.parent && cur.parent !== "root" ? menu.items[cur.parent] : null
  }
  return false
}

// Searchable rows: actions run their command, submenus open the Omarchy menu there.
function searchMenu(menu, hidden, query, limit, usage, now) {
  var list = []
  for (var i = 0; i < menu.order.length; i++) {
    var e = menu.items[menu.order[i]]
    if (!e || e.parent === "") continue
    if (!e.action && !e.target && e.provider === undefined && !hasChildren(menu, e.id)) continue
    if (menuHiddenUpwards(menu, hidden || {}, e.id)) continue
    list.push(e)
  }
  var found = topScored(list, function(e) {
    var aliases = Array.isArray(e.aliases) ? e.aliases.join(" ") : String(e.aliases || "")
    return textScore(e.label, [e.description || "", aliases, e.id.replace(/[.\-]/g, " ")].join(" "), query)
  }, limit || 5, function(a, b) { return frecency(usage, "menu:" + b.id, now) - frecency(usage, "menu:" + a.id, now) })
  return found.map(function(e) {
    var path = menuPath(menu.items, e.id)
    var aliases = Array.isArray(e.aliases) ? e.aliases.join(" ") : String(e.aliases || "")
    return {
      score: rowScore(e.label, [e.description || "", aliases, e.id.replace(/[.\-]/g, " ")].join(" "), query),
      id: e.id, label: e.label, icon: String(e.icon || ""), description: String(e.description || ""),
      path: path, action: e.action ? String(e.action) : "",
      // A link opens its target; a submenu opens itself.
      route: e.action ? "" : (e.target ? String(e.target) : e.id)
    }
  })
}

function hasChildren(menu, id) {
  for (var i = 0; i < menu.order.length; i++) {
    var e = menu.items[menu.order[i]]
    if (e && e.parent === id) return true
  }
  return false
}

// MARK: keybindings

// `omarchy-menu-keybindings --print`: "SUPER SHIFT + F      → File manager".
function parseKeybindings(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var at = line.indexOf("→")
    if (at < 0) continue
    var keys = line.slice(0, at).trim().replace(/\s+\+\s+/g, " + ")
    var desc = line.slice(at + 1).trim()
    if (keys && desc) out.push({ keys: keys, desc: desc, line: line })
  }
  return out
}

function searchBindings(list, query, limit) {
  return topScored(list || [], function(b) { return textScore(b.desc, b.keys, query) }, limit || 3)
}

// MARK: windows

// `hyprctl clients -j` → open windows matching by title or class, never this bar.
function searchWindows(clients, query, limit) {
  var list = (Array.isArray(clients) ? clients : []).filter(function(c) {
    return c && c.mapped !== false && c.hidden !== true && /^0x[0-9a-fA-F]+$/.test(String(c.address || ""))
      && String(c.title || c["class"] || "")
  })
  return topScored(list, function(c) {
    var cls = String(c["class"] || "")
    var s1 = textScore(cls, "", query)
    var s2 = textScore(c.title, "", query)
    var best = s1 < 0 ? s2 : s2 < 0 ? s1 : Math.min(s1, s2)
    return best
  }, limit || 3, function(a, b) { return (a.focusHistoryID || 0) - (b.focusHistoryID || 0) })
}

// MARK: calculator

// "2*(3+4)", "2^10", "1,5 + 2", "-2^2". No eval: a small recursive-descent
// parser over numbers, + - * / % ^ and parentheses. Returns null unless the
// text is a complete expression with at least one operator, and for text that
// is more likely a date or a phone number (2025-10-13, 8-800-555-35-35) or a
// number with thousands separators (1,000), so Enter still opens the file.
function calculate(text) {
  var raw = String(text || "").trim()
  if (/^\d+([-/.]\d+){2,}$/.test(raw) || /\d,\d{3}(\D|$)/.test(raw)) return null
  var src = raw.replace(/×/g, "*").replace(/÷/g, "/").replace(/(\d),(\d)/g, "$1.$2")
  if (!/^[\d\s.+\-*/%^()]+$/.test(src) || !/[+\-*/%^]/.test(src.replace(/^\s*-/, "")) || !/\d/.test(src)) return null
  var pos = 0
  function peek() { while (src.charAt(pos) === " ") pos++; return src.charAt(pos) }
  function number() {
    var m = /^\d*\.?\d+(?:e[+-]?\d+)?/i.exec(src.slice(pos))
    if (!m) throw 0
    pos += m[0].length
    return parseFloat(m[0])
  }
  function primary() {
    var c = peek()
    if (c === "(") { pos++; var v = expr(); if (peek() !== ")") throw 0; pos++; return v }
    return number()
  }
  // Unary minus binds looser than ^, as in maths: -2^2 is -4.
  function power() {
    var c = peek()
    if (c === "-") { pos++; return -power() }
    if (c === "+") { pos++; return power() }
    var base = primary()
    if (peek() === "^") { pos++; return Math.pow(base, power()) }
    return base
  }
  function term() {
    var v = power()
    for (;;) {
      var c = peek()
      if (c === "*") { pos++; v *= power() }
      else if (c === "/") { pos++; v /= power() }
      else if (c === "%") { pos++; v = v % power() }
      else return v
    }
  }
  function expr() {
    var v = term()
    for (;;) {
      var c = peek()
      if (c === "+") { pos++; v += term() }
      else if (c === "-") { pos++; v -= term() }
      else return v
    }
  }
  try {
    var result = expr()
    if (peek() !== "") return null
    var rounded = Math.round(result * 1e10) / 1e10
    return isFinite(rounded) ? rounded : null
  } catch (e) {
    return null
  }
}

// MARK: Claude limits

// The record Omarchy's agent-usage collector writes for Claude → the two limits.
function claudeUsage(raw) {
  var d
  try { d = JSON.parse(raw) } catch (e) { return null }
  if (!d || !Array.isArray(d.limits) || d.limits.length === 0) return null
  function pick(re) {
    for (var i = 0; i < d.limits.length; i++) {
      var l = d.limits[i]
      if (l && re.test(String(l.label || "")) && typeof l.percent === "number")
        return { percent: Math.round(l.percent * 100), resetsAt: String(l.resetsAt || "") }
    }
    return null
  }
  var session = pick(/session|5-hour/i)
  var week = pick(/week|7-day/i)
  return session || week ? { session: session, week: week } : null
}

if (typeof module !== "undefined") module.exports = {
  looksLikeQuestion: looksLikeQuestion, appScore: appScore, searchApps: searchApps,
  filterFiles: filterFiles, baseName: baseName, dirName: dirName, tildify: tildify,
  parseStreamLine: parseStreamLine, explainError: explainError,
  safeMarkdown: safeMarkdown, isWebLink: isWebLink,
  textScore: textScore, rowScore: rowScore, parseHiddenIds: parseHiddenIds, frecency: frecency, recordUse: recordUse,
  stripJsonc: stripJsonc, parseMenu: parseMenu, menuPath: menuPath, menuGuardScript: menuGuardScript,
  parseGuardOutput: parseGuardOutput, searchMenu: searchMenu, parseKeybindings: parseKeybindings,
  searchBindings: searchBindings, searchWindows: searchWindows, calculate: calculate, claudeUsage: claudeUsage
}
