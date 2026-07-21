#!/usr/bin/env bash
# Fail early when the selected Node.js runtime cannot run locked semantic-release.
set -euo pipefail

required='^22.14.0 or >=24.10.0'
node_binary="${NODE_BINARY:-node}"
raw_version="${1:-$("$node_binary" --version)}"
raw_version="${raw_version%$'\r'}"
version="${raw_version#v}"

if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Unsupported Node.js version '$raw_version': semantic-release 25.0.8 requires $required." >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
if (( (major == 22 && minor >= 14) || (major == 24 && minor >= 10) || major > 24 )); then
  exit 0
fi

echo "Unsupported Node.js $raw_version: semantic-release 25.0.8 requires $required." >&2
exit 1
