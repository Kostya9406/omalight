<p align="center"><img src="icon.svg" width="96" alt="OmaLight"></p>

<h1 align="center">OmaLight</h1>

<p align="center">A Spotlight-style bar for <a href="https://omarchy.org">Omarchy</a>: find apps and files, or ask Claude and read the answer streamed right in the bar.</p>

![OmaLight answering a question](preview.png)

- **One input for everything.** Apps from your desktop entries, files and folders in your home, and an "Ask Claude" row on top.
- **It tells a search from a question.** Text ending in `?`, four or more words, or starting with a question word (*how*, *what*, *why*, *как*, *что*…) lands on "Ask Claude". Anything else lands on the first app or file.
- **Answers stream in place**, rendered as Markdown. Press ↵ again to ask a follow-up in the same conversation.
- **Uses your Claude subscription** through the official [Claude Code](https://claude.com/claude-code) CLI. No API key. The default model is the newest **Haiku**, which is fast and light on your limits.
- **Looks like Omarchy.** It runs inside `omarchy-shell` and follows the active theme. The interface is in English, or Russian on a Russian locale.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` (Omarchy Quattro).
- [Claude Code](https://claude.com/claude-code) installed and signed in: run `claude` once in a terminal and log in.
- `plocate` for file search. Omarchy ships it; the index refreshes daily, or run `sudo updatedb` for an immediate refresh.

## Install

```bash
omarchy plugin add https://github.com/Kostya9406/omalight.git --enable
```

OmaLight never changes your config, so bind a key yourself. Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("ALT + SPACE", "OmaLight", "omarchy-shell shell toggle io.github.kostya9406.omalight")
```

Any free key works. Omarchy already uses <kbd>Super</kbd>+<kbd>Space</kbd> for its menu.

### Options

Pass a JSON payload in the binding:

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
| <kbd>↵</kbd> | open the selected app or file, or ask Claude on the first row |
| <kbd>Ctrl</kbd>+<kbd>↵</kbd> | always ask Claude |
| <kbd>Alt</kbd>+<kbd>↵</kbd> | open the file's folder |
| <kbd>↑</kbd> <kbd>↓</kbd> · <kbd>Tab</kbd> · <kbd>Ctrl</kbd>+<kbd>J</kbd>/<kbd>K</kbd> | pick a result |
| <kbd>↵</kbd> after an answer | ask a follow-up |
| <kbd>Ctrl</kbd>+<kbd>C</kbd> | copy the last answer |
| <kbd>Ctrl</kbd>+<kbd>N</kbd> | start a new conversation |
| <kbd>PgUp</kbd> <kbd>PgDn</kbd> | scroll the answer |
| <kbd>Esc</kbd> | stop the answer → back to search → clear → close |

## Privacy and safety

- Search stays local. Only text you send to Claude leaves the machine, to Anthropic through your own `claude` CLI.
- Claude runs as `claude --safe-mode -p`, which loads none of your CLAUDE.md files, hooks, plugins or MCP servers. The only tools allowed are **WebSearch** and **WebFetch**: it cannot read your files or run commands.
- Sessions are kept in `~/.local/state/omalight` (Claude Code's own session storage), so follow-ups can `--resume` them.
- Answers are untrusted text. Images and raw HTML are stripped before rendering, so nothing is fetched without a click, and only `http(s)` links open.
- Typed text and file paths reach programs only as separate arguments, never through a shell.

## Uninstall

```bash
omarchy plugin remove io.github.kostya9406.omalight
rm -rf ~/.local/state/omalight
```

Remove the `OmaLight` line from `~/.config/hypr/bindings.lua`.

## Development

- `OmaLight.qml`: the overlay. `Search.js`: matching, ranking and stream parsing. `Strings.js`: interface text. `Icon.js` and `YinYang.qml`: the mark.
- `node tests/search.test.js` runs the logic tests.
- `node tools/make-icon.js [color] > icon.svg` redraws the icon from the same grid the overlay paints.
- `omarchy-shell` caches compiled QML, so run `omarchy restart shell` after editing.

## Credits

Modelled on [Lumi](https://github.com/AlbertS15/Lumi) by AlbertS15 (MIT). The question-word list and the search-or-question heuristic are adapted from it.

## License

[MIT](LICENSE)
