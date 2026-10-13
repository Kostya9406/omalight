// node tests/search.test.js
const assert = require("assert")
const S = require("../Search.js")

assert.strictEqual(S.looksLikeQuestion("firefox"), false)
assert.strictEqual(S.looksLikeQuestion("как включить bluetooth"), true)
assert.strictEqual(S.looksLikeQuestion("bluetooth?"), true)
assert.strictEqual(S.looksLikeQuestion("one two three four"), true)
assert.strictEqual(S.looksLikeQuestion("   "), false)

const apps = [
  { id: "firefox", name: "Firefox", genericName: "Web Browser" },
  { id: "org.gnome.Nautilus", name: "Files", genericName: "File Manager" },
  { id: "hidden", name: "Firefox Helper", noDisplay: true },
  { id: "chromium", name: "Chromium", genericName: "Web Browser", keywords: ["fox"] },
  { id: "tor", name: "Tor Browser" },
]
assert.deepStrictEqual(S.searchApps(apps, "fir").map(a => a.id), ["firefox"])
assert.deepStrictEqual(S.searchApps(apps, "browser").map(a => a.id), ["tor", "chromium", "firefox"])
assert.deepStrictEqual(S.searchApps(apps, "fox").map(a => a.id), ["firefox", "chromium"])
assert.deepStrictEqual(S.searchApps(apps, "zzz"), [])

const home = "/home/u"
const out = [
  "f\t/home/u/Documents/long/path/report.pdf",
  "d\t/home/u/report",
  "f\t/home/u/.cache/report.txt",
  "f\t/home/u/proj/node_modules/report.js",
  "f\t/etc/report",
  "f\t/home/u/a/report-2024.xlsx",
  "garbage",
  "",
].join("\n")
const files = S.filterFiles(out, home, "report")
assert.deepStrictEqual(files.map(f => f.path), ["/home/u/report", "/home/u/a/report-2024.xlsx", "/home/u/Documents/long/path/report.pdf"])
assert.strictEqual(files[0].dir, true)
assert.strictEqual(S.tildify("/home/u/a", home), "~/a")

assert.deepStrictEqual(S.parseStreamLine('{"type":"system","subtype":"init","session_id":"abc"}'), { kind: "session", id: "abc" })
assert.deepStrictEqual(S.parseStreamLine('{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"hi"}}}'), { kind: "text", text: "hi" })
assert.deepStrictEqual(S.parseStreamLine('{"type":"result","is_error":true,"result":"Please run /login"}'), { kind: "error", text: "Please run /login" })
assert.deepStrictEqual(S.parseStreamLine('{"type":"result","is_error":false}'), { kind: "done" })
assert.strictEqual(S.parseStreamLine("not json"), null)
assert.deepStrictEqual(S.explainError("Please run /login"), { key: "errAuth", detail: "" })
assert.deepStrictEqual(S.explainError(""), { key: "errFailed", detail: "" })
assert.deepStrictEqual(S.explainError("boom"), { key: "", detail: "boom" })

const T = require("../Strings.js")
assert.strictEqual(T.isRussian("ru_RU"), true)
assert.strictEqual(T.isRussian("en_US"), false)
assert.strictEqual(T.tr("ask", false), "Ask Claude")
assert.strictEqual(T.tr("ask", true), "Спросить Claude")
for (const [key, pair] of Object.entries(T.TEXT)) assert.ok(pair.length === 2 && pair[0] && pair[1], key)

const I = require("../Icon.js")
const cells = I.yinYangCells(16)
assert.ok(cells.length > 60 && cells.length < 200)
assert.ok(cells.every(([x, y]) => x >= 0 && x < 16 && y >= 0 && y < 16))
assert.strictEqual(S.safeMarkdown("a ![leak](https://evil/?d=x) b"), "a leak b")
assert.strictEqual(S.safeMarkdown("![x][r]\n[r]: https://evil/p.png"), "x\n")
assert.strictEqual(S.safeMarkdown('hi <img src="https://evil/x"> **b**'), "hi  **b**")
assert.strictEqual(S.safeMarkdown("[link](https://ok.org) `code`"), "[link](https://ok.org) `code`")
assert.strictEqual(S.isWebLink("https://wiki.archlinux.org/x"), true)
assert.strictEqual(S.isWebLink("file:///etc/passwd"), false)
assert.strictEqual(S.isWebLink("foo.desktop"), false)
assert.strictEqual(S.isWebLink("steam://run/1"), false)
console.log("ok")
