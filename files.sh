#!/bin/bash
# Files and folders in $HOME whose name contains $1, for the OmaLight search.
# Output: "q<TAB><query>" first, so the overlay can never match it to a newer
# query, then one "d<TAB><path>" (folder) or "f<TAB><path>" (file) per line.
#
# plocate answers from its index, which refreshes once a day; fd fills the gap
# with what changed since the index was built, so a file saved a minute ago is
# found too. Hidden paths and node_modules are dropped before the cut, so they
# cannot crowd out real results.

q=$1
printf 'q\t%s\n' "$q"

{
  if command -v fd >/dev/null 2>&1; then
    db=/var/lib/plocate/plocate.db
    since=()
    [[ -e $db ]] && since=(--changed-after "$(date -d "@$(stat -c %Y "$db")" '+%F %T')")
    timeout 2 fd --ignore-case --fixed-strings --no-ignore --exclude node_modules --exclude .git \
      "${since[@]}" -- "$q" "$HOME" 2>/dev/null
  fi
  plocate -i -b -- "$q" 2>/dev/null
} | sed 's:/$::' | grep -F "$HOME/" | grep -v -e '/\.' -e '/node_modules/' | awk '!seen[$0]++' | head -n 300 |
  while IFS= read -r p; do
    if [[ -d $p ]]; then printf 'd\t%s\n' "$p"; else printf 'f\t%s\n' "$p"; fi
  done
