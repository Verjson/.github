#!/usr/bin/env bash
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
outside="$(mktemp -d)" || exit 1
trap 'rm -rf -- "$outside"' EXIT INT TERM

if (cd -- "$outside" && bash "$root/scripts/ci-gate/runner-routing-policy.test.sh" >/dev/null); then
  echo "ok - runner-routing policy is independent of caller cwd"
  exit 0
fi

echo "not ok - runner-routing policy failed outside repository cwd" >&2
exit 1
