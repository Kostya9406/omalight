#!/bin/bash
# Files and folders in $HOME whose name contains $OMALIGHT_QUERY, for the
# OmaLight search.
# Output: "q<TAB><query>" first, so the overlay can never match it to a newer
# query, then one "d<TAB><path>" (folder) or "f<TAB><path>" (file) per line,
# then "end": output without it was cut short and counts as a failed search.
#
# fd walks the whole home folder on every search (tens of milliseconds for a
# hundred thousand files once they are in the page cache), so a file saved a
# second ago is found too. It skips hidden paths and node_modules, and stays on
# the home file system, so a hung network mount under ~ cannot stall the search.
# A walk that does not finish in 3 seconds (a cold cache on a huge home) prints
# no "end": a partial list must not pass for "nothing else matches".
#
# The text comes in the environment, never as an argument: any local user can
# read a process's arguments in /proc, but not its environment. For the same
# reason fd gets no pattern: grep reads the text from a pipe to narrow the list
# down quickly, then awk keeps the paths whose last part (the name) matches.
# Matches are ranked before the cut, as the overlay ranks them (exact name,
# then names starting with the text, then shorter paths), so the 300 kept are
# the best ones and the same every time. Paths that are gone by the time they
# are printed, or pieces of a name with a newline in it, are dropped before the
# cut so they cannot crowd out real results.

q=${OMALIGHT_QUERY-}
printf 'q\t%s\n' "$q"
[[ -n $q ]] || { printf 'end\n'; exit 0; }

# --foreground keeps fd in this process group, so the overlay's own timeout
# reaches it too.
timeout --foreground -k 1 3 fd --no-ignore --one-file-system --exclude node_modules \
    --search-path "$HOME" 2>/dev/null |
  grep -iF -f <(printf '%s\n' "$q") 2>/dev/null |
  awk -F/ 'BEGIN { q = tolower(ENVIRON["OMALIGHT_QUERY"]) }
           { n = $NF; if (n == "" && NF > 1) n = $(NF - 1); l = tolower(n); i = index(l, q)
             if (i) printf "%d\t%d\t%s\n", (l == q ? 0 : i == 1 ? 1 : 2), length($0), $0 }' 2>/dev/null |
  LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3 | cut -f3- |
  sed 's:/$::' | grep -F "$HOME/" | grep -v -e '/\.' -e '/node_modules/' |
  while IFS= read -r p; do [[ -e $p || -L $p ]] && printf '%s\n' "$p"; done | head -n 300 |
  while IFS= read -r p; do
    if [[ -d $p ]]; then printf 'd\t%s\n' "$p"; else printf 'f\t%s\n' "$p"; fi
  done
# fd timed out (124, or 137 once killed) or is missing (127).
(( PIPESTATUS[0] == 0 )) || exit 1
printf 'end\n'
