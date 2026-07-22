#!/usr/bin/env bash
# Tests the reusable node-ci.yml optional Postgres DB-service step
# (Verjson/.github#108). The step is default-off: callers that don't set
# `db-image` get no database and no behavior change. When `db-image` is set, the
# step starts Postgres via `docker run` (there is no `if:` on a `services:`
# block, and an empty image is a hard error, so a conditional step is the only
# non-breaking toggle) and exports the caller's `db-env` pairs — including
# DATABASE_URL — to `$GITHUB_ENV` for later steps. This extracts the exact `run:`
# block from node-ci.yml (single source of truth, so the test can't drift) and
# exercises it against a stubbed `docker`. Plain bash + awk; no test-framework
# dependency (runs on the bare pool).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/node-ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# (a) Default-off: the DB step must be guarded by an `inputs.db-image` check so
# callers that leave it empty never start a database.
guard="$(awk '
  $0 == "        id: db-service" { seen = 1 }
  seen && $0 ~ /^        if:/ { print; exit }
' "$wf")"
printf '%s' "$guard" | grep -qF "inputs.db-image != ''" \
  && pass "DB step is guarded by inputs.db-image (default-off, no DB for current callers)" \
  || fail "DB step is not gated on inputs.db-image (would force a DB on every caller)"

# Extract the DB step's run script verbatim (10-space-indented body under
# `run: |`, scoped to the step with `id: db-service`).
script="$tmp/db.sh"
awk '
  $0 == "        id: db-service" { seen = 1 }
  seen && $0 == "        run: |" { cap = 1; next }
  cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
' "$wf" >"$script"
if ! grep -q 'GITHUB_ENV' "$script" || ! grep -q 'docker run' "$script"; then
  echo "FAIL - could not extract DB-service run block from $wf"
  echo "$fails test(s) failed."
  exit 1
fi

# Stub `docker`: `run` succeeds and records its args; `exec ... pg_isready`
# reports ready immediately so the health-wait loop breaks on the first probe.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
exit 0
DOCKER
chmod +x "$tmp/bin/docker"

# (b) When db-image is set, DATABASE_URL (and the POSTGRES_* pairs) reach the
# test step via $GITHUB_ENV, and the POSTGRES_* pairs are passed into the
# container.
export PATH="$tmp/bin:$PATH"
export DOCKER_LOG="$tmp/docker.log"
export GITHUB_ENV="$tmp/github_env"
: >"$DOCKER_LOG"
: >"$GITHUB_ENV"
# The workflow supplies CONTAINER_NAME via the step `env:` (a run-scoped name);
# mirror that here so the extracted script runs under `set -u`.
export CONTAINER_NAME="ci-postgres-test"
export DB_IMAGE="pgvector/pgvector:pg16"
export DB_ENV="POSTGRES_USER=app
POSTGRES_PASSWORD=secret
POSTGRES_DB=app_test
DATABASE_URL=postgres://app:secret@localhost:5432/app_test"

bash "$script" >"$tmp/out.txt" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { echo "---- db step output ----"; cat "$tmp/out.txt"; }

grep -qF 'DATABASE_URL=postgres://app:secret@localhost:5432/app_test' "$GITHUB_ENV" \
  && pass "DATABASE_URL is exported to \$GITHUB_ENV for the test step" \
  || fail "DATABASE_URL was not written to \$GITHUB_ENV"

grep -qF 'POSTGRES_DB=app_test' "$GITHUB_ENV" \
  && pass "POSTGRES_* pairs are exported to \$GITHUB_ENV" \
  || fail "POSTGRES_* pairs were not written to \$GITHUB_ENV"

grep -qF -- '-e POSTGRES_USER=app' "$DOCKER_LOG" \
  && pass "POSTGRES_* env is passed into the database container" \
  || fail "POSTGRES_* env was not passed into the container"

grep -qF -- "$DB_IMAGE" "$DOCKER_LOG" \
  && pass "the caller-supplied db-image is the container started" \
  || fail "the caller db-image was not started"

grep -qF -- '--name "$CONTAINER_NAME"' "$script" \
  && pass "the container uses a run-scoped name (no cross-job collision)" \
  || fail "the container name is not run-scoped (would collide on a shared runner)"

# (c) A teardown step must always remove the run-scoped container so a finished
# or failed job never leaks it onto the persistent self-hosted runner.
teardown="$(awk '
  $0 == "      - name: Stop database service" { seen = 1 }
  seen && $0 ~ /^        if:/ { print; found = 1 }
  seen && $0 ~ /docker rm -f/ { print; found = 1 }
  seen && $0 ~ /^      - name:/ && $0 != "      - name: Stop database service" { exit }
' "$wf")"
{ printf '%s' "$teardown" | grep -qF 'always()' && printf '%s' "$teardown" | grep -qF 'docker rm -f'; } \
  && pass "a Stop database service step always removes the container (if: always())" \
  || fail "no always() teardown for the DB container (it would leak on the self-hosted runner)"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
