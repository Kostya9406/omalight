#!/bin/bash
# bash tests/files.test.sh — files.sh against a stand-in plocate, no real index needed.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

home="$tmp/home"
mkdir -p "$home/docs/.hidden" "$home/node_modules" "$home/Report-new" "$home/reports/x" "$tmp/bin"
touch "$home/docs/report.txt" "$home/docs/.hidden/report.txt" "$home/node_modules/report.js" "$home/reports/x/other.txt"

# The index still lists a file deleted since, a hidden one, one in node_modules,
# one outside home and a name broken by a newline.
cat > "$tmp/bin/plocate" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/plocate.args"
printf '%s\n' "$home/docs/report.txt" "$home/docs/gone-report.txt" "$home/docs/.hidden/report.txt" \
  "$home/node_modules/report.js" "/etc/report" "$home/docs/half" "of a report"
STUB
# fd lists what changed since the index, with no pattern; files.sh matches the
# names itself (a folder above the file does not count).
cat > "$tmp/bin/fd" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/fd.args"
printf '%s\n' "$home/Report-new/" "$home/reports/x/other.txt"
STUB
chmod +x "$tmp/bin/plocate" "$tmp/bin/fd"

out=$(HOME="$home" PATH="$tmp/bin:$PATH" OMALIGHT_QUERY=REPORT bash "$here/files.sh")
want=$(printf 'q\tREPORT\nd\t%s\nf\t%s\nend' "$home/Report-new" "$home/docs/report.txt")
if [[ $out != "$want" ]]; then
  printf 'files.sh output:\n%s\n\nexpected:\n%s\n' "$out" "$want" >&2
  exit 1
fi

# The text never reaches fd's arguments; plocate is the one place it must go.
if grep -qi report "$tmp/fd.args"; then echo "the typed text reached fd's arguments" >&2; exit 1; fi
grep -q -- '-- REPORT' "$tmp/plocate.args" || { echo "plocate did not get the text" >&2; exit 1; }

# An argument is never taken for the text.
out=$(HOME="$home" PATH="$tmp/bin:$PATH" bash "$here/files.sh" report)
if [[ $out != $'q\t\nend' ]]; then printf 'an argument was searched for:\n%s\n' "$out" >&2; exit 1; fi
echo "ok files"
