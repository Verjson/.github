#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$root/scripts/shellcheck-tracked.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$repo/scripts"

cat >"$repo/scripts/clean.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' clean
SH

cat >"$repo/scripts/name with spaces.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'space-safe'
SH

cat >"$repo/scripts/untracked-warning.sh" <<'SH'
#!/usr/bin/env bash
cd "$1"
printf '%s\n' done
SH

git -C "$repo" add -- scripts/clean.sh 'scripts/name with spaces.sh'

if (cd "$repo" && bash "$runner"); then
  pass "tracked clean scripts pass while an untracked warning is ignored"
else
  fail "tracked clean scripts failed or the untracked fixture was linted"
fi

git -C "$repo" add -- scripts/untracked-warning.sh
if output="$(cd "$repo" && bash "$runner" 2>&1)"; then
  fail "tracked standalone warning passed ShellCheck"
elif grep -qF 'scripts/untracked-warning.sh' <<<"$output" \
  && grep -qF 'SC2164 (warning)' <<<"$output"; then
  pass "tracked standalone warning fails with its ShellCheck diagnostic"
else
  printf '%s\n' "$output" >&2
  fail "tracked standalone warning failed without the expected diagnostic"
fi

empty_repo="$tmp/empty-repo"
git init -q "$empty_repo"
if (cd "$empty_repo" && bash "$runner"); then
  pass "a repository without tracked shell scripts is a successful no-op"
else
  fail "empty tracked shell set failed"
fi

exit "$fails"
