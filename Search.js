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

function searchApps(entries, query) {
  var scored = []
  var seen = {}
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (!e || e.noDisplay) continue
    var score = appScore(e, query)
    if (score < 0) continue
    var key = String(e.id || e.name)
    if (seen[key]) continue
    seen[key] = true
    scored.push({ score: score, entry: e })
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
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

// Model output is untrusted (web pages it read can steer it). Qt's Markdown
// renderer fetches images on its own, so an image could carry the conversation
// out in its URL without a click: keep only the alt text. Raw HTML goes too.
function safeMarkdown(text) {
  return String(text || "")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/!\[([^\]]*)\]\[[^\]]*\]/g, "$1")
    .replace(/^\s*\[[^\]]+\]:\s*\S+.*$/gm, "")
    .replace(/<\/?[A-Za-z][^>]*>/g, "")
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

if (typeof module !== "undefined") module.exports = {
  looksLikeQuestion: looksLikeQuestion, appScore: appScore, searchApps: searchApps,
  filterFiles: filterFiles, baseName: baseName, dirName: dirName, tildify: tildify,
  parseStreamLine: parseStreamLine, explainError: explainError,
  safeMarkdown: safeMarkdown, isWebLink: isWebLink
}
