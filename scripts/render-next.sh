#!/usr/bin/env bash
# Renders canonical metadata-driven NEXT/ fragments.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$repo_root/scripts/changelog.py" render-next --repo-root "$repo_root"
