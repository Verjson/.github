#!/usr/bin/env bash
# Renders canonical metadata-driven NEXT/ fragments.
#
# Arguments pass through to the engine, so `--as-released` shows the shape a
# release would publish — the one nobody sees until it can no longer be changed.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$repo_root/scripts/changelog.py" render-next --repo-root "$repo_root" "$@"
