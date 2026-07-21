#!/usr/bin/env bash
# Generates the reverse-chronological ADR index table in
# docs/decisions/README.md from each NNNN-*/README.md, so no PR ever hand-edits
# the shared table (add your ADR directory; the table is derived).
#
#   scripts/gen-adr-index.sh            # rewrite the table in place (between markers)
#   scripts/gen-adr-index.sh --check    # exit 1 if the committed table is stale
#
# Each ADR's row is [NNNN](dir/README.md) | <Date field> | <H1 title>. The H1
# (`# NNNN — Title`) is the canonical decision statement, so the index can't drift
# from the ADR. Pure bash + awk — runs on the bare self-hosted pool.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dec_dir="$root/docs/decisions"
index="$dec_dir/README.md"
begin='<!-- BEGIN ADR INDEX -->'
end='<!-- END ADR INDEX -->'

tmp_table=""
trap 'rm -f "$tmp_table"' EXIT

valid_date() {
  local value="$1" year month day max_day
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  year=$((10#${value:0:4}))
  month=$((10#${value:5:2}))
  day=$((10#${value:8:2}))
  [ "$year" -ge 1 ] && [ "$month" -ge 1 ] && [ "$month" -le 12 ] && [ "$day" -ge 1 ] || return 1
  case "$month" in
    2)
      max_day=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then max_day=29; fi
      ;;
    4|6|9|11) max_day=30 ;;
    *) max_day=31 ;;
  esac
  [ "$day" -le "$max_day" ]
}

gen_table() {
  printf '| # | Date | Decision |\n'
  printf '|---|------|----------|\n'
  local d slug num readme title date
  # Reverse sort by directory name → highest ADR number first.
  while IFS= read -r d; do
    slug="$(basename "$d")"
    num="${slug%%-*}"
    readme="$d/README.md"
    [ -f "$readme" ] || { echo "gen-adr-index: $slug/ has no README.md — an ADR directory must contain one" >&2; exit 1; }
    # H1 title, stripped of the leading "NNNN — " / "NNNN - " prefix.
    title="$(awk '
      /^# / && !seen {
        sub(/^# */, "")
        sub(/^[0-9]+ *— */, "")
        sub(/^[0-9]+ *- */, "")
        print; seen = 1
      }' "$readme")"
    # "- **Date:** YYYY-MM-DD" → the value.
    date="$(awk '
      index($0, "**Date:**") {
        s = substr($0, index($0, "**Date:**") + 9)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        print s; exit
      }' "$readme")"
    if [ -z "$title" ] || [ -z "$date" ]; then
      echo "gen-adr-index: $slug/README.md missing an '# NNNN — Title' H1 or '- **Date:**' line" >&2
      exit 1
    fi
    if ! valid_date "$date"; then
      echo "gen-adr-index: $slug/README.md has invalid date '$date' — expected a valid YYYY-MM-DD calendar date" >&2
      exit 1
    fi
    printf '| [%s](%s/README.md) | %s | %s |\n' "$num" "$slug" "$date" "$title"
  done < <(find "$dec_dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-*' | sort -r)
}

render() {
  tmp_table="$(mktemp)"
  gen_table >"$tmp_table"
  awk -v tf="$tmp_table" -v b="$begin" -v e="$end" '
    $0 == b { print; while ((getline line < tf) > 0) print line; close(tf); skip = 1; next }
    $0 == e { skip = 0; print; next }
    !skip { print }
  ' "$index"
}

grep -qF "$begin" "$index" && grep -qF "$end" "$index" || {
  echo "gen-adr-index: both markers '$begin' and '$end' must be present in $index" >&2
  exit 1
}

if [ "${1:-}" = "--check" ]; then
  if ! diff -u "$index" <(render); then
    echo "gen-adr-index: docs/decisions/README.md is stale — run scripts/gen-adr-index.sh and commit." >&2
    exit 1
  fi
  echo "ADR index is up to date."
else
  render >"$index.tmp" && mv "$index.tmp" "$index"
  echo "Regenerated ADR index in $index"
fi
