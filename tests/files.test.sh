#!/bin/bash
# bash tests/files.test.sh — files.sh against a stand-in fd, no real home folder walked.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

home="$tmp/home"
mkdir -p "$home/docs/.hidden" "$home/node_modules" "$home/Report-new" "$home/reports/x" "$tmp/bin"
touch "$home/docs/report.txt" "$home/docs/.hidden/report.txt" "$home/node_modules/report.js" \
  "$home/reports/x/other.txt" "$home/docs/rep.ort" "$home/reports/x/Report"

# fd lists everything, with no pattern; files.sh matches the names itself (a
# folder above the file does not count). The list still has a file deleted
# since, a hidden one, one in node_modules, one outside home, a name broken by a
# newline, and a name that matches the text only as a regular expression.
# FD_SLEEP makes it hang like a walk over a cold cache.
cat > "$tmp/bin/fd" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/fd.args"
[ -z "\$FD_SLEEP" ] || exec sleep "\$FD_SLEEP"
printf '%s\n' "$home/Report-new/" "$home/reports/x/other.txt" "$home/docs/report.txt" \
  "$home/docs/gone-report.txt" "$home/docs/.hidden/report.txt" "$home/node_modules/report.js" \
  "/etc/report" "$home/docs/half" "of a report" "$home/docs/rep.ort" "$home/reports/x/Report"
STUB
# plocate takes its pattern only as an argument, so it must not run at all.
cat > "$tmp/bin/plocate" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/plocate.args"
STUB
# Every other command logs its arguments and runs the real one.
for c in timeout grep awk sort cut sed head; do
  real=$(command -v "$c")
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexec "%s" "$@"\n' "$c" "$tmp/argv.log" "$real" > "$tmp/bin/$c"
done
chmod +x "$tmp/bin/"*

out=$(HOME="$home" PATH="$tmp/bin:$PATH" OMALIGHT_QUERY=REPORT bash "$here/files.sh")
# Ranked as the overlay ranks them: exact name, then names starting with the
# text, then shorter paths.
want=$(printf 'q\tREPORT\nf\t%s\nd\t%s\nf\t%s\nend' "$home/reports/x/Report" "$home/Report-new" "$home/docs/report.txt")
if [[ $out != "$want" ]]; then
  printf 'files.sh output:\n%s\n\nexpected:\n%s\n' "$out" "$want" >&2
  exit 1
fi

# The text is matched literally, not as a pattern.
out=$(HOME="$home" PATH="$tmp/bin:$PATH" OMALIGHT_QUERY=rep.ort bash "$here/files.sh")
want=$(printf 'q\trep.ort\nf\t%s\nend' "$home/docs/rep.ort")
if [[ $out != "$want" ]]; then printf 'rep.ort was not matched literally:\n%s\n' "$out" >&2; exit 1; fi

# The text never reaches a process's arguments.
if grep -qi -e report -e rep.ort "$tmp/fd.args" "$tmp/argv.log"; then
  echo "the typed text reached a process's arguments:" >&2; grep -i -e report -e rep.ort "$tmp/argv.log" >&2; exit 1
fi
grep -q '^grep -iF -f /dev/fd/' "$tmp/argv.log" || { echo "grep no longer reads the text from a pipe" >&2; exit 1; }
if [[ -e $tmp/plocate.args ]]; then echo "plocate ran: $(cat "$tmp/plocate.args")" >&2; exit 1; fi

# A walk that runs out of time prints no "end", so it is never taken for "nothing else".
out=$(HOME="$home" PATH="$tmp/bin:$PATH" OMALIGHT_QUERY=report FD_SLEEP=10 bash "$here/files.sh") && rc=0 || rc=$?
if [[ $out == *end || $rc == 0 ]]; then printf 'a timed-out walk passed for complete (rc %s):\n%s\n' "$rc" "$out" >&2; exit 1; fi

# An argument is never taken for the text.
out=$(env -u OMALIGHT_QUERY HOME="$home" PATH="$tmp/bin:$PATH" bash "$here/files.sh" report)
if [[ $out != $'q\t\nend' ]]; then printf 'an argument was searched for:\n%s\n' "$out" >&2; exit 1; fi
echo "ok files"
