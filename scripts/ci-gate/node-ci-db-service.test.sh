#!/usr/bin/env bash
# Tests the reusable node-ci.yml optional Postgres DB-service step
# (Verjson/.github#108). The step is default-off: callers that don't set
# `db-image` get no database and no behavior change. When `db-image` is set, the
# step starts Postgres via `docker run` (there is no `if:` on a `services:`
# block, and an empty image is a hard error, so a conditional step is the only
# non-breaking toggle) and exports the caller's `db-env` pairs — including
# DATABASE_URL — to `$GITHUB_ENV` for later steps. It must also stay safe when
# two DB-backed jobs share one self-hosted host (#116). This extracts the exact
# `run:` block from node-ci.yml (single source of truth, so the test can't
# drift) and exercises it against a stubbed `docker`. Plain bash + awk; no
# test-framework dependency (runs on the bare pool).
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
# reports ready immediately so the health-wait loop breaks on the first probe;
# `port` reports the host port the daemon assigned this invocation's container.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
# `MAPPED_PORT=` (set but empty) models a daemon that reports no host mapping.
[ "${1:-}" = "port" ] && printf '%s:%s\n' "${MAPPED_HOST:-127.0.0.1}" "${MAPPED_PORT-0}"
exit 0
DOCKER
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"

export DB_IMAGE="pgvector/pgvector:pg16"
export DB_ENV="POSTGRES_USER=app
POSTGRES_PASSWORD=secret
POSTGRES_DB=app_test
DATABASE_URL=postgres://app:secret@localhost:5432/app_test"
# Run-level identity is shared by every job of one workflow run — it is exactly
# what two DB-backed jobs of the same run cannot be told apart by.
export GITHUB_RUN_ID="7000000001"
export GITHUB_RUN_ATTEMPT="1"

# Run the extracted step in its own sandbox so two "concurrent jobs" can be
# compared: each invocation gets a private docker log, $GITHUB_ENV and
# $GITHUB_OUTPUT. Trailing KEY=VALUE args apply to that invocation only.
run_db_step() {
  local box="$tmp/$1"; shift
  mkdir -p "$box"
  : >"$box/docker.log"; : >"$box/github_env"; : >"$box/github_output"
  env DOCKER_LOG="$box/docker.log" GITHUB_ENV="$box/github_env" \
      GITHUB_OUTPUT="$box/github_output" "$@" \
      bash -eo pipefail "$script" >"$box/out.txt" 2>&1
}

# The container name the step actually used, read back from the docker stub log.
container_name_of() {
  sed -n 's/.*--name \([^ ]*\).*/\1/p' "$tmp/$1/docker.log" | head -n1
}

# Two DB-backed jobs sharing one self-hosted host. Inside the reusable they even
# share a job id (`build-test`) — what differs is the runner process serving
# them, because a runner executes one job at a time.
job_a=(GITHUB_JOB=build-test MAPPED_PORT=49187
       RUNNER_NAME=gcp-pool-1 RUNNER_WORKSPACE=/runner-1/_work/api)
job_b=(GITHUB_JOB=build-test MAPPED_PORT=49188
       RUNNER_NAME=gcp-pool-2 RUNNER_WORKSPACE=/runner-2/_work/web)

# (b) When db-image is set, DATABASE_URL (and the POSTGRES_* pairs) reach the
# test step via $GITHUB_ENV, and the POSTGRES_* pairs are passed into the
# container.
run_db_step job-a "${job_a[@]}"
rc=$?
[ "$rc" -eq 0 ] || { echo "---- db step output ----"; cat "$tmp/job-a/out.txt"; }

grep -qE '^DATABASE_URL=postgres://app:secret@localhost:[0-9]+/app_test$' "$tmp/job-a/github_env" \
  && pass "DATABASE_URL is exported to \$GITHUB_ENV for the test step" \
  || fail "DATABASE_URL was not written to \$GITHUB_ENV"

grep -qF 'POSTGRES_DB=app_test' "$tmp/job-a/github_env" \
  && pass "POSTGRES_* pairs are exported to \$GITHUB_ENV" \
  || fail "POSTGRES_* pairs were not written to \$GITHUB_ENV"

grep -qF -- '-e POSTGRES_USER=app' "$tmp/job-a/docker.log" \
  && pass "POSTGRES_* env is passed into the database container" \
  || fail "POSTGRES_* env was not passed into the container"

grep -qF -- "$DB_IMAGE" "$tmp/job-a/docker.log" \
  && pass "the caller-supplied db-image is the container started" \
  || fail "the caller db-image was not started"

# (c) Concurrency: run_id/run_attempt alone are shared by every job of a run, so
# a name scoped only by them collides the moment two DB-backed jobs land on one
# host (#116). The step must fold the job's own identity into the name.
run_db_step job-b "${job_b[@]}"
rc=$?
[ "$rc" -eq 0 ] || { echo "---- db step output ----"; cat "$tmp/job-b/out.txt"; }
name_a="$(container_name_of job-a)"
name_b="$(container_name_of job-b)"
{ [ -n "$name_a" ] && [ -n "$name_b" ] && [ "$name_a" != "$name_b" ]; } \
  && pass "two concurrent DB-backed jobs on one host get distinct container names" \
  || fail "both jobs used the container name '$name_a' (the second docker run would fail: name already in use)"

# (d) The container must publish on an OS-assigned host port: a fixed 5432:5432
# bind fails outright for the second DB-backed job on the host (#116).
{ grep -qE -- '-p [^ ]*::5432' "$tmp/job-a/docker.log" \
    && ! grep -qE -- '-p [0-9.]+:5432 ' "$tmp/job-a/docker.log"; } \
  && pass "the container publishes on an OS-assigned host port (no fixed bind)" \
  || fail "the container binds a fixed host port (a second DB-backed job on the host cannot start): $(grep -o -- '-p [^ ]*' "$tmp/job-a/docker.log" | head -n1)"

# (e) The published port is OS-assigned, so the caller's DATABASE_URL cannot
# name it up front: the step must read the mapped port back from docker and
# rewrite the connection URL it exports, or `npm test` dials a port nothing is
# listening on.
grep -qF 'DATABASE_URL=postgres://app:secret@localhost:49187/app_test' "$tmp/job-a/github_env" \
  && pass "the exported DATABASE_URL carries the host port docker actually mapped" \
  || fail "exported DATABASE_URL does not use the mapped port 49187: $(grep '^DATABASE_URL=' "$tmp/job-a/github_env" || echo '<absent>')"

# Hardening: a URL that omits the port used to work, because the container was
# bound to the well-known 5432 — with an OS-assigned port it would silently dial
# the wrong port, so the step must fill the port in. Values that are not URLs, or
# URLs on some other port (a caller's REDIS_URL), must be passed through
# untouched.
run_db_step job-c "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
DATABASE_URL=postgres://app@localhost/app_test
REDIS_URL=redis://localhost:6379"
rc=$?
[ "$rc" -eq 0 ] || { echo "---- db step output ----"; cat "$tmp/job-c/out.txt"; }
{ grep -qF 'DATABASE_URL=postgres://app@localhost:49187/app_test' "$tmp/job-c/github_env" \
    && grep -qF 'REDIS_URL=redis://localhost:6379' "$tmp/job-c/github_env" \
    && grep -qF 'POSTGRES_USER=app' "$tmp/job-c/github_env"; } \
  && pass "a portless db-env URL gets the mapped port; other values pass through verbatim" \
  || fail "portless URL was not pointed at the mapped port (or another value was rewritten): $(grep -c . "$tmp/job-c/github_env") lines, $(grep '^DATABASE_URL=' "$tmp/job-c/github_env" || echo '<absent>')"

# Hardening: docker reports an IPv6 mapping as `[::]:PORT`, so the readback must
# take the port, not everything after the first colon.
run_db_step job-v6 "${job_a[@]}" MAPPED_HOST='[::]' MAPPED_PORT=49222
grep -qF 'DATABASE_URL=postgres://app:secret@localhost:49222/app_test' "$tmp/job-v6/github_env" \
  && pass "an IPv6-shaped port mapping ([::]:PORT) still yields the host port" \
  || fail "IPv6 mapping was mis-parsed: $(grep '^DATABASE_URL=' "$tmp/job-v6/github_env" || echo '<absent>')"

# Hardening: if the port can't be read back there is no usable connection at all,
# so the step must fail instead of exporting a URL pointing nowhere.
run_db_step job-noport "${job_a[@]}" MAPPED_PORT=
rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^DATABASE_URL=' "$tmp/job-noport/github_env"; } \
  && pass "an unreadable port mapping fails the step instead of exporting a dead URL" \
  || fail "step exited $rc and exported $(grep '^DATABASE_URL=' "$tmp/job-noport/github_env" || echo 'no URL') despite an unreadable port"

# (f) A teardown step must always remove the container so a finished or failed
# job never leaks it onto the persistent self-hosted runner — AND it must stay
# gated on inputs.db-image so it only runs for DB-backed callers. Assert the two
# conditions are on the SAME `if:` line (#115): checking that `always()` merely
# appears somewhere would pass even if the db-image guard were dropped, making
# teardown run unconditionally on every caller.
teardown_if="$(awk '
  $0 == "      - name: Stop database service" { seen = 1; next }
  seen && $0 ~ /^        if:/ { print; exit }
  seen && $0 ~ /^      - name:/ { exit }
' "$wf")"
teardown_body="$(awk '
  $0 == "      - name: Stop database service" { seen = 1 }
  seen && $0 ~ /docker rm -f/ { print }
  seen && $0 ~ /^      - name:/ && $0 != "      - name: Stop database service" { exit }
' "$wf")"
{ printf '%s' "$teardown_if" | grep -qF 'always()' \
    && printf '%s' "$teardown_if" | grep -qF "inputs.db-image" \
    && printf '%s' "$teardown_body" | grep -qF 'docker rm -f'; } \
  && pass "teardown if: combines always() with the inputs.db-image guard and removes the container" \
  || fail "teardown must gate always() on inputs.db-image on the same if: line (else it runs unconditionally)"

# (g) Teardown must remove the container the start step actually created. A
# per-job name is only safe if cleanup can still find it, so the start step
# publishes the name it computed and teardown consumes that — re-deriving a
# run-scoped literal would leave every DB container behind on the host.
teardown_script="$tmp/teardown.sh"
awk '
  $0 == "      - name: Stop database service" { seen = 1; next }
  seen && $0 ~ /^      - name:/ { exit }
  seen && $0 == "        run: |" { cap = 1; next }
  seen && cap {
    if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
    if ($0 ~ /^[ \t]*$/) { print ""; next }
    cap = 0
  }
  seen && !cap && $0 ~ /^        run: / { sub(/^        run: /, ""); print }
' "$wf" >"$teardown_script"
teardown_name_expr="$(awk '
  $0 == "      - name: Stop database service" { seen = 1; next }
  seen && $0 ~ /^      - name:/ { exit }
  seen && $0 ~ /^          CONTAINER_NAME: / { sub(/^          CONTAINER_NAME: /, ""); print; exit }
' "$wf")"
# Resolve the teardown env expression the way the runner would, from the start
# step's published outputs and the run context.
published_name="$(sed -n 's/^container-name=//p' "$tmp/job-a/github_output" | head -n1)"
resolved_name="$teardown_name_expr"
resolved_name="${resolved_name//\$\{\{ steps.db-service.outputs.container-name \}\}/$published_name}"
resolved_name="${resolved_name//\$\{\{ github.run_id \}\}/$GITHUB_RUN_ID}"
resolved_name="${resolved_name//\$\{\{ github.run_attempt \}\}/$GITHUB_RUN_ATTEMPT}"
mkdir -p "$tmp/teardown"
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_NAME="$resolved_name" \
  bash "$teardown_script" >"$tmp/teardown/out.txt" 2>&1
grep -qF -- "rm -f $name_a" "$tmp/teardown/docker.log" \
  && pass "teardown removes the exact container the start step created" \
  || fail "teardown targeted '$resolved_name' but the start step created '$name_a' (container would leak on the host)"

# Hardening: teardown also runs when the start step never reached `docker run`
# (its output is then empty) — it must be a no-op, not a `docker rm -f ""`.
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_NAME="" \
  bash "$teardown_script" >"$tmp/teardown/out-empty.txt" 2>&1
[ ! -s "$tmp/teardown/docker.log" ] \
  && pass "teardown is a no-op when no container was started" \
  || fail "teardown called docker with no container name: $(cat "$tmp/teardown/docker.log")"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
