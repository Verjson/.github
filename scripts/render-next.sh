#!/usr/bin/env bash
# Renders the running log from the NEXT/ changelog fragments, newest first.
# Each NEXT/*.md (except this dir's README.md) is one entry; filenames sort
# reverse-chronologically, so a blank-line-separated reverse sort is the log.
# 0000-archive.md holds pre-split history and naturally sorts last.
# Pure bash — runs on the bare self-hosted pool, no extra tooling.
set -euo pipefail

next_dir="$(cd "$(dirname "$0")/.." && pwd)/NEXT"
[ -d "$next_dir" ] || { echo "render-next: no NEXT/ directory at $next_dir" >&2; exit 1; }

mapfile -t fragments < <(cd "$next_dir" && ls -1 ./*.md 2>/dev/null | sed 's#^\./##' | grep -vx 'README.md' | sort -r)
if [ "${#fragments[@]}" -eq 0 ]; then
  echo "render-next: no fragments in $next_dir" >&2
  exit 1
fi

first=1
for f in "${fragments[@]}"; do
  [ "$first" = 1 ] || printf '\n'
  cat "$next_dir/$f"
  first=0
done
