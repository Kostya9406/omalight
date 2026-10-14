#!/bin/bash
# Files and folders in $HOME whose name contains $OMALIGHT_QUERY, for the
# OmaLight search.
# Output: "q<TAB><query>" first, so the overlay can never match it to a newer
# query, then one "d<TAB><path>" (folder) or "f<TAB><path>" (file) per line,
# then "end": output without it was cut short and counts as a failed search.
#
# plocate answers from its index, which refreshes once a day; fd fills the gap
# with what changed since the index was built, so a file saved a minute ago is
# found too. Paths that no longer exist (deleted or moved since the index was
# built, or pieces of a name with a newline in it) are dropped, as are hidden
# paths and node_modules, all before the cut so they cannot crowd out real
# results. fd stays on the home file system, so a hung network mount under ~
# cannot stall the search (plocate already skips network file systems).
#
# The text comes in the environment, never as an argument: any local user can
# read a process's arguments in /proc, but not its environment. For the same
# reason fd gets no pattern and awk matches its list against the environment.
# plocate takes its pattern only as an argument, so there the text is visible
# for the fraction of a second plocate runs.

q=${OMALIGHT_QUERY-}
printf 'q\t%s\n' "$q"
[[ -n $q ]] || { printf 'end\n'; exit 0; }

{
  if command -v fd >/dev/null 2>&1; then
    db=/var/lib/plocate/plocate.db
    since=()
    [[ -e $db ]] && since=(--changed-after "$(date -d "@$(stat -c %Y "$db")" '+%F %T')")
    timeout 2 fd --no-ignore --one-file-system --exclude node_modules --exclude .git \
      "${since[@]}" --search-path "$HOME" 2>/dev/null |
      awk 'BEGIN { q = tolower(ENVIRON["OMALIGHT_QUERY"]) }
           { n = $0; sub(/\/$/, "", n); sub(/.*\//, "", n); if (index(tolower(n), q)) print }' 2>/dev/null
  fi
  plocate -i -b -- "$q" 2>/dev/null
} | sed 's:/$::' | grep -F "$HOME/" | grep -v -e '/\.' -e '/node_modules/' | awk '!seen[$0]++' |
  while IFS= read -r p; do [[ -e $p || -L $p ]] && printf '%s\n' "$p"; done | head -n 300 |
  while IFS= read -r p; do
    if [[ -d $p ]]; then printf 'd\t%s\n' "$p"; else printf 'f\t%s\n' "$p"; fi
  done
printf 'end\n'
