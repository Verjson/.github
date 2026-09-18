#!/usr/bin/env bash
# Run the changelog contract this repository publishes against this repository's
# own pull request (Verjson/.github#1425).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
engine="$here/../changelog.py"
repo_root="$(cd "${1:-$here/../..}" && pwd)"

exec python3 "$engine" validate \
  --repo-root "$repo_root" --base origin/main --head HEAD
