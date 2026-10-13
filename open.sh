#!/bin/bash
# Opens a file or folder from the OmaLight search in its default app, the way
# the file manager would.
#   $1  the path
#   $2  the notice shown when no app can open it (OmaLight passes it localized)
#
# gio picks the app by name as well as content (so README.md gets the Markdown
# app, not the plain-text one) and starts Terminal=true apps such as nvim in
# the default terminal through xdg-terminal-exec. xdg-open is no fallback: it
# has no terminal support (nvim would start with no window), and for a type
# with no app it opens an empty browser window.

path=$1
notice=${2:-"No app can open this file; showing its folder."}

gio open "$path" 2>/dev/null && exit 0

# Nothing is registered for this type: say so and show where the file is.
notify-send -a OmaLight "${path##*/}" "$notice" 2>/dev/null
exec gio open "$(dirname -- "$path")"
