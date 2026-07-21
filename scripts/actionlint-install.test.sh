#!/usr/bin/env bash
# Tests the exact actionlint installer run block with stubbed download/extraction
# commands. A checksum mismatch must stop before an archive is extracted or a
# downloaded binary executes (Verjson/.github#83).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wf="$(cd "$here/.." && pwd)/.github/workflows/actionlint.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

script="$tmp/install.sh"
awk '
  $0 == "      - name: Install actionlint (pinned release binary)" { seen = 1 }
  seen && $0 == "        run: |" { capture = 1; next }
  capture {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    capture = 0
  }
' "$wf" >"$script"
if ! grep -q 'sha256sum --check --strict' "$script" || ! grep -q 'tar -xzf' "$script"; then
  echo "FAIL - could not extract checksum-verifying installer from $wf"
  exit 1
fi

pinned="$(awk '$1 == "ACTIONLINT_SHA256:" {gsub(/['\''\"]/, "", $2); print $2; exit}' "$wf")"
[[ "$pinned" =~ ^[0-9a-f]{64}$ ]] \
  && pass "workflow pins a full SHA-256 digest" \
  || fail "workflow checksum is missing or malformed"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; break; fi
  shift
done
printf '%s' "$DOWNLOAD_CONTENT" >"$out"
SH
cat >"$tmp/bin/tar" <<'SH'
#!/usr/bin/env bash
echo TAR >>"$ACTIONLOG"
cat > actionlint <<'BIN'
#!/usr/bin/env bash
echo EXEC >>"$ACTIONLOG"
BIN
chmod +x actionlint
SH
chmod +x "$tmp/bin/curl" "$tmp/bin/tar"

run_case() {
  local checksum="$1" case_dir
  case_dir="$(mktemp -d "$tmp/case.XXXXXX")"
  export PATH="$tmp/bin:$PATH"
  export ACTIONLINT_VERSION=1.7.7 ACTIONLINT_SHA256="$checksum"
  export DOWNLOAD_CONTENT='fixture archive bytes'
  export ACTIONLOG="$case_dir/actions.log"
  : >"$ACTIONLOG"
  (cd "$case_dir" && bash "$script") >"$case_dir/out.txt" 2>&1
  RUN_RC=$?
}

good="$(printf '%s' 'fixture archive bytes' | sha256sum | awk '{print $1}')"
run_case "$good"; rc="$RUN_RC"
{ [ "$rc" -eq 0 ] && grep -q TAR "$ACTIONLOG" && grep -q EXEC "$ACTIONLOG"; } \
  && pass "matching checksum permits extraction and execution" \
  || fail "matching checksum did not complete installer"

bad="0${good:1}"
[ "${good:0:1}" = 0 ] && bad="1${good:1}"
run_case "$bad"; rc="$RUN_RC"
{ [ "$rc" -ne 0 ] && ! grep -q TAR "$ACTIONLOG" && ! grep -q EXEC "$ACTIONLOG"; } \
  && pass "checksum mismatch fails before extraction or execution (#83)" \
  || fail "checksum mismatch was not fail-closed (#83)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
