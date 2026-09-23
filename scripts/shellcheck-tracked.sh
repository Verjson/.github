#!/usr/bin/env bash
set -euo pipefail

git ls-files -z -- '*.sh' \
  | xargs -0 -r shellcheck --severity=warning --
