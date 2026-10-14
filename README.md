<p align="center"><img src="icon.svg" width="96" alt="OmaLight"></p>

<h1 align="center">OmaLight</h1>

<p align="center">A Spotlight-style bar for <a href="https://omarchy.org">Omarchy</a>: find apps and files, or ask Claude and read the answer streamed right in the bar.</p>

![OmaLight answering a question](preview.png)

- **One input for everything.** Apps, open windows, every action in the Omarchy menu, your keybindings, files and folders in your home, sums, and an "Ask Claude" row on top. Results of every kind are ranked together by how well they match.
- **Speaks Omarchy.** Apps Omarchy hides stay hidden, actions show where they live (*Omarchy › Style › Theme*), keybindings run through Omarchy's own dispatcher, and launching an app shows the same "Launching…" notice as the Omarchy menu. Apps you launch often rise to the top.
- **It tells a search from a question.** Text ending in `?`, four or more words, or starting with a question word (*how*, *what*, *why*, *как*, *что*…) lands on "Ask Claude". Anything else lands on the first app or file.
- **Only what you ask goes to Claude.** <kbd>↵</kbd> on the "Ask Claude" row it picked by itself waits for the file search to finish, so a file name typed quickly opens the file. A file or app named exactly like the text is picked even when the text reads like a question; for text that does not read like a question, a file still gives way to apps and keybindings found for it. When text that does not read like a question finds nothing, the first <kbd>↵</kbd> says so and the second asks Claude. Text pasted with line breaks skips the file search.
- **Answers stream in place**, rendered as Markdown. Press ↵ again to ask a follow-up in the same conversation.
- **Uses your Claude subscription** through the official [Claude Code](https://claude.com/claude-code) CLI. No API key. The default model is the newest **Haiku**, which is fast and light on your limits; <kbd>Ctrl</kbd>+<kbd>M</kbd> switches to Sonnet or Opus. Claude gets Omarchy's own agent guide, so answers about your system name the right files and keys.
- **On the bar.** A pixel yin-yang next to your workspaces opens the bar; its tooltip shows Claude's session and weekly limits, which the bar also shows next to the model name.
- **Looks like Omarchy.** It runs inside `omarchy-shell` and follows the active theme. The interface is in English, or Russian on a Russian locale.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` (Omarchy Quattro).
- [Claude Code](https://claude.com/claude-code) installed and signed in: run `claude` once in a terminal and log in.
- `fd` for file search; Omarchy ships it. Each search walks your home folder afresh (skipping hidden folders and `node_modules`), so new files are found right away. It stays on the home file system: disks mounted inside your home folder are not searched.

## Install

```bash
omarchy plugin add https://github.com/Kostya9406/omalight.git --enable
```

Enabling adds the mark to the left of the bar; move it with `omarchy bar move io.github.kostya9406.omalight --section right`, or turn on *Show Claude's session limit* in the widget's settings.

OmaLight never changes your config, so bind a key yourself. Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("ALT + SPACE", "OmaLight", "omarchy-shell shell toggle io.github.kostya9406.omalight")
```

Any free key works. Omarchy already uses <kbd>Super</kbd>+<kbd>Space</kbd> for its menu.

To open it from the Omarchy menu too, add a row to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"omalight": {"icon":"\uf002","label":"OmaLight","description":"Find apps, files, actions, or ask Claude","action":"omarchy-shell shell toggle io.github.kostya9406.omalight"},
```

### Options

Pass a JSON payload in the binding. Both are remembered, so the bar widget and the menu row open with the same choice:

| Key | Values | Default |
|---|---|---|
| `model` | any `claude --model` value: `haiku`, `sonnet`, `opus`, or a full model id | `haiku` |
| `lang` | `en`, `ru` | system locale |

```lua
o.bind("ALT + SPACE", "OmaLight", "omarchy-shell shell toggle io.github.kostya9406.omalight '{\"model\":\"sonnet\",\"lang\":\"en\"}'")
```

## Keys

| Key | Action |
|---|---|
| <kbd>↵</kbd> | open, switch to, run or copy the selected result, or ask Claude on the first row (see below) |
| <kbd>Ctrl</kbd>+<kbd>↵</kbd> | always ask Claude |
| <kbd>Alt</kbd>+<kbd>↵</kbd> | open the file's folder (does nothing on the "Ask Claude" row) |
| <kbd>↑</kbd> <kbd>↓</kbd> · <kbd>Tab</kbd> · <kbd>Ctrl</kbd>+<kbd>J</kbd>/<kbd>K</kbd> | pick a result |
| <kbd>↵</kbd> after an answer | ask a follow-up |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> · <kbd>Super</kbd>+<kbd>C</kbd> | copy the last answer (Omarchy's universal copy works too, over terminals as well) |
| <kbd>Ctrl</kbd>+<kbd>V</kbd> · <kbd>Super</kbd>+<kbd>V</kbd> | paste into the bar |
| <kbd>Ctrl</kbd>+<kbd>N</kbd> | start a new conversation |
| <kbd>Ctrl</kbd>+<kbd>M</kbd> | switch the model: Haiku → Sonnet → Opus (or click its name) |
| <kbd>PgUp</kbd> <kbd>PgDn</kbd> | scroll the answer |
| <kbd>Esc</kbd> | stop the answer → back to search → clear → close |

## Privacy and safety

- Search stays local. Only text you send to Claude leaves the machine, to Anthropic through your own `claude` CLI, along with Omarchy's public agent guide from `$OMARCHY_PATH/default/agents/skills/omarchy`.
- Claude runs as `claude --safe-mode -p`, which loads none of your CLAUDE.md files, hooks, plugins or MCP servers. The only tools allowed are **WebSearch** and **WebFetch**: it cannot read your files or run commands.
- OmaLight's own files are in `~/.local/state/omalight`: `settings.json` (model and language), `usage.json` (how often you launch what) and `picker/`, a two-line stand-in for `omarchy-menu-select` that lets a keybinding row run through `omarchy-menu-keybindings`. Claude runs from that folder, so its conversations are not mixed into your projects.
- The conversations themselves are stored by Claude Code, like any `claude` session, in `~/.claude/projects/-home-<you>--local-state-omalight/` (one `.jsonl` file per conversation, questions and answers included). Claude Code removes old ones itself after `cleanupPeriodDays` (30 days by default), or delete them as below. That is what lets a follow-up `--resume` the conversation.
- Omarchy menu actions run exactly as the Omarchy menu runs them: they are commands from Omarchy and from your own menu extension.
- Answers are untrusted text, so before rendering an invisible character (U+2060) goes between `!` and `[` and after every `<`, everywhere, code included: no image or HTML tag can form, and OmaLight adds no HTML of its own, so an answer cannot make the bar fetch anything without a click. Links open only on a click, and only `http(s)` ones (they keep Qt's default colour for that reason). Copying an answer gives the original text.
- Typed text never goes through a shell. Other local users can read any process's arguments in `/proc`, so the text you search for and the questions you ask are handed over in the environment (readable only by you) and on stdin, not as arguments: `fd` lists your home folder with no pattern, and the names are matched inside OmaLight's own pipeline. File paths you open are passed as arguments.

## Uninstall

```bash
omarchy plugin remove io.github.kostya9406.omalight
rm -rf ~/.local/state/omalight                     # settings, launch counts
rm -rf ~/.claude/projects/*--local-state-omalight  # Claude's OmaLight conversations
```

With `CLAUDE_CONFIG_DIR` set, the conversations are under that folder's `projects/` instead.

Remove the `OmaLight` line from `~/.config/hypr/bindings.lua`.

## Development

- `files.sh`: the file search (fd over your home folder); try it with `OMALIGHT_QUERY=<name> bash files.sh`.
- `open.sh`: opens a result in its default app through `gio`, so apps that run in a terminal (nvim for text files) open in your terminal; with no app for the type it shows the file's folder.
- `OmaLight.qml`: the overlay. `BarWidget.qml`: the bar mark. `Search.js`: matching, ranking, the calculator, the Omarchy menu and keybinding readers, and stream parsing. `Strings.js`: interface text. `Icon.js` and `YinYang.qml`: the mark.
- `node tests/search.test.js` runs the logic tests; `bash tests/files.test.sh` checks `files.sh` against a stand-in fd.
- `node tools/make-icon.js [color] > icon.svg` redraws the icon from the same grid the overlay paints.
- `omarchy-shell` caches compiled QML, so run `omarchy restart shell` after editing.

## Credits

Modelled on [Lumi](https://github.com/AlbertS15/Lumi) by AlbertS15 (MIT). The question-word list and the search-or-question heuristic are adapted from it.

## License

[MIT](LICENSE). Adapted third-party parts and their notices are listed in [NOTICE](NOTICE).
