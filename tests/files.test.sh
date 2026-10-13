#!/bin/bash
# bash tests/files.test.sh — files.sh against a stand-in plocate, no real index needed.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

home="$tmp/home"
mkdir -p "$home/docs/.hidden" "$home/node_modules" "$tmp/bin"
touch "$home/docs/report.txt" "$home/docs/.hidden/report.txt" "$home/node_modules/report.js"

# The index still lists a file deleted since, a hidden one, one in node_modules,
# one outside home and a name broken by a newline.
cat > "$tmp/bin/plocate" <<EOF
#!/bin/sh
printf '%s\n' "$home/docs/report.txt" "$home/docs/gone-report.txt" "$home/docs/.hidden/report.txt" \
  "$home/node_modules/report.js" "/etc/report" "$home/docs/half" "of a report"
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/fd"
chmod +x "$tmp/bin/plocate" "$tmp/bin/fd"

out=$(HOME="$home" PATH="$tmp/bin:$PATH" bash "$here/files.sh" report)
want=$(printf 'q\treport\nf\t%s\nend' "$home/docs/report.txt")
if [[ $out != "$want" ]]; then
  printf 'files.sh output:\n%s\n\nexpected:\n%s\n' "$out" "$want" >&2
  exit 1
fi
echo "ok files"
