#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
pass(){ printf 'ok   - %s\n' "$1"; }
fail(){ printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

guard="$(awk '$0=="        id: cache-service"{f=1} f&&/^        if:/{print;exit}' "$workflow")"
grep -qF "inputs.cache-image != ''" <<< "$guard" \
  && pass "cache service is default-off" || fail "cache service is not guarded by cache-image"

start="$tmp/start.sh"
awk '
  $0=="        id: cache-service"{f=1}
  f&&/^      - name:/{exit}
  f&&$0=="        run: |"{r=1;next}
  r { if(substr($0,1,10)=="          "){print substr($0,11);next}; if($0~/^[[:space:]]*$/){print "";next}; exit }
' "$workflow" > "$start"

teardown="$tmp/teardown.sh"
awk '
  $0=="      - name: Stop cache service"{f=1}
  f&&$0=="        run: |"{r=1;next}
  r { if(substr($0,1,10)=="          "){print substr($0,11);next}; if($0~/^[[:space:]]*$/){print "";next}; exit }
' "$workflow" > "$teardown"

mkdir "$tmp/bin"
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  run) printf 'cache-container-id\n' ;;
  port) printf '127.0.0.1:%s\n' "${MAPPED_PORT:-49321}" ;;
  exec) printf 'PONG\n' ;;
  ps) printf '%s' "${STALE_CONTAINERS:-}" ;;
  rm) [ -z "${RM_FAIL:-}" ] || { printf '%s\n' "$RM_FAIL" >&2; exit 1; } ;;
esac
SH
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" CACHE_IMAGE=redis:8 CACHE_ENV='REDIS_URL=redis://127.0.0.1:${CACHE_PORT}
REDIS_MODE=test' GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=build-test
export RUNNER_NAME=runner-1 RUNNER_WORKSPACE=/runner/_work/example

run_start(){
  : > "$tmp/docker.log"; : > "$tmp/env"; : > "$tmp/output"
  DOCKER_LOG="$tmp/docker.log" GITHUB_ENV="$tmp/env" GITHUB_OUTPUT="$tmp/output" \
    MAPPED_PORT="${MAPPED_PORT:-49321}" bash -eo pipefail "$start" >"$tmp/out" 2>&1
}

if run_start \
  && grep -Fxq 'CACHE_PORT=49321' "$tmp/env" \
  && grep -Fxq 'REDIS_URL=redis://127.0.0.1:49321' "$tmp/env" \
  && grep -Fq -- '-p 127.0.0.1::6379' "$tmp/docker.log" \
  && grep -Fq -- 'ps -a --filter label=verjson-ci-cache=1' "$tmp/docker.log" \
  && grep -Fq -- '-e REDIS_MODE=test' "$tmp/docker.log" \
  && grep -Fq 'exec cache-container-id redis-cli ping' "$tmp/docker.log"; then
  pass "cache starts on a dynamic loopback port and exports substituted environment"
else
  fail "cache start contract failed: $(tail -1 "$tmp/out")"
fi

if grep -Fxq 'container-id=cache-container-id' "$tmp/output"; then
  pass "cache publishes its immutable container handle"
else
  fail "cache did not publish its container id"
fi

bad_env='not-a-pair'
if CACHE_ENV="$bad_env" run_start; then
  fail "malformed cache-env was accepted"
else
  pass "malformed cache-env fails at the input boundary"
fi

: > "$tmp/docker.log"
if DOCKER_LOG="$tmp/docker.log" CONTAINER_ID=cache-container-id bash "$teardown" \
  && grep -Fxq 'rm -f cache-container-id' "$tmp/docker.log"; then
  pass "cache teardown removes exactly the published container"
else
  fail "cache teardown did not remove the published container"
fi

: > "$tmp/docker.log"
DOCKER_LOG="$tmp/docker.log" CONTAINER_ID= bash "$teardown"
[ ! -s "$tmp/docker.log" ] && pass "empty cache handle makes teardown a no-op" \
  || fail "empty cache handle invoked Docker"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."; exit 1
