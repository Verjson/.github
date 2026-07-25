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
# `run: |`, scoped to the step with `id: db-service`). Stop at the next step's
# `- name:`, or the teardown step's own `run: |` gets appended to the start
# script and the harness silently exercises the two together.
script="$tmp/db.sh"
awk '
  $0 == "        id: db-service" { seen = 1 }
  seen && $0 ~ /^      - name:/ { exit }
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
case "${1:-}" in
  run)
    # `docker run -d` prints the container ID it assigned. When $DOCKER_NAMES is
    # set the stub also enforces the daemon's real rule that a name is unique on
    # the host, so a name collision can be modelled.
    name=""; prev=""
    for arg in "$@"; do [ "$prev" = "--name" ] && name="$arg"; prev="$arg"; done
    if [ -n "${DOCKER_NAMES:-}" ]; then
      if grep -qxF "$name" "$DOCKER_NAMES" 2>/dev/null; then
        printf 'docker: Error response from daemon: Conflict. The container name "/%s" is already in use.\n' \
          "$name" >&2
        exit 125
      fi
      printf '%s\n' "$name" >>"$DOCKER_NAMES"
    fi
    seq=$(( $(cat "$DOCKER_IDSEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$seq" >"$DOCKER_IDSEQ"
    printf 'c0ffeeba5e%06d\n' "$seq"
    ;;
  # `MAPPED_PORT=` (set but empty) models a daemon that reports no host mapping.
  port) printf '%s:%s\n' "${MAPPED_HOST:-127.0.0.1}" "${MAPPED_PORT-0}" ;;
  ps) printf '%s' "${STALE_CONTAINERS:-}" ;;
  # $RM_FAIL models a removal the daemon refuses, message and all.
  rm) [ -z "${RM_FAIL:-}" ] || { printf '%s\n' "$RM_FAIL" >&2; exit 1; } ;;
esac
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
  env DOCKER_LOG="$box/docker.log" DOCKER_IDSEQ="$tmp/docker-idseq" \
      GITHUB_ENV="$box/github_env" GITHUB_OUTPUT="$box/github_output" "$@" \
      bash -eo pipefail "$script" >"$box/out.txt" 2>&1
}

# The container name the step actually used, read back from the docker stub log.
container_name_of() {
  sed -n 's/.*--name \([^ ]*\).*/\1/p' "$tmp/$1/docker.log" | head -n1
}

# The handle the step published for teardown to consume.
published_handle_of() {
  sed -n 's/^container-id=//p' "$tmp/$1/github_output" | head -n1
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

# (c2) Runner identity is what separates two jobs of one run, and only one of the
# two parts needs to differ: a runner name may repeat across hosts while the
# workspace path does not (and vice versa).
run_db_step job-same-name GITHUB_JOB=build-test MAPPED_PORT=49401 \
  RUNNER_NAME=gcp-pool-1 RUNNER_WORKSPACE=/runner-1/_work/api
run_db_step job-same-ws GITHUB_JOB=build-test MAPPED_PORT=49402 \
  RUNNER_NAME=gcp-pool-1 RUNNER_WORKSPACE=/runner-1/_work/web
[ "$(container_name_of job-same-name)" != "$(container_name_of job-same-ws)" ] \
  && pass "jobs differing in only one of RUNNER_NAME/RUNNER_WORKSPACE still get distinct names" \
  || fail "both jobs used '$(container_name_of job-same-name)' (a differing workspace alone did not separate them)"

# (c3) The name premise can fail outright: with GITHUB_JOB constant inside this
# reusable and RUNNER_NAME/RUNNER_WORKSPACE both absent, two jobs of one run hash
# identically. Docker then refuses the second `docker run --name`, and that job
# MUST fail with no handle to tear down — a name-based handle would let it
# `docker rm -f` the FIRST job's live container and kill a healthy job.
clash_names="$tmp/docker-names"; : >"$clash_names"
run_db_step job-clash-a GITHUB_JOB=build-test MAPPED_PORT=49501 \
  RUNNER_NAME= RUNNER_WORKSPACE= DOCKER_NAMES="$clash_names"
rc_clash_a=$?
run_db_step job-clash-b GITHUB_JOB=build-test MAPPED_PORT=49502 \
  RUNNER_NAME= RUNNER_WORKSPACE= DOCKER_NAMES="$clash_names"
rc_clash_b=$?
{ [ "$rc_clash_a" -eq 0 ] && [ "$rc_clash_b" -ne 0 ] \
    && [ -n "$(published_handle_of job-clash-a)" ] \
    && [ -z "$(published_handle_of job-clash-b)" ]; } \
  && pass "a name collision fails the losing job and gives it no handle to tear down" \
  || fail "collision left rc_a=$rc_clash_a rc_b=$rc_clash_b handle_b='$(published_handle_of job-clash-b)' (job B could remove job A's container)"

# (d) The container must publish on an OS-assigned host port: a fixed 5432:5432
# bind fails outright for the second DB-backed job on the host (#116).
{ grep -qE -- '-p [^ ]*::5432' "$tmp/job-a/docker.log" \
    && ! grep -qE -- '-p [0-9.]+:5432 ' "$tmp/job-a/docker.log"; } \
  && pass "the container publishes on an OS-assigned host port (no fixed bind)" \
  || fail "the container binds a fixed host port (a second DB-backed job on the host cannot start): $(grep -o -- '-p [^ ]*' "$tmp/job-a/docker.log" | head -n1)"

# (d2) A leaked container used to announce itself by breaking the next job's
# 5432 bind; with an OS-assigned port it is invisible and accumulates on a
# persistent host. So the container is labelled, and each start sweeps aged
# containers carrying that label — best-effort, and scoped by the label so it can
# never touch anything that isn't ours.
grep -qF -- '--label verjson-ci=1' "$tmp/job-a/docker.log" \
  && pass "the database container is labelled so leaks can be found later" \
  || fail "the container carries no verjson-ci label (a leak would be unidentifiable)"

run_db_step job-sweep "${job_a[@]}" STALE_CONTAINERS=$'aa11bb22\ncc33dd44'
rc=$?
{ [ "$rc" -eq 0 ] \
    && grep -qE '^ps .*label=verjson-ci=1' "$tmp/job-sweep/docker.log" \
    && grep -qE '^rm -f .*aa11bb22' "$tmp/job-sweep/docker.log" \
    && grep -qE '^rm -f .*cc33dd44' "$tmp/job-sweep/docker.log"; } \
  && pass "aged containers carrying the CI label are swept before the job's own starts" \
  || fail "step exited $rc without sweeping leaked labelled containers: $(grep -E '^(ps|rm) ' "$tmp/job-sweep/docker.log" | tr '\n' ' ')"

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

# Hardening: the host-port rewrite must anchor the right-hand edge of `:5432`.
# `54320`-`54322` are common alternate-Postgres ports and `:5432` is a prefix of
# all of them, so an unanchored match mangles a caller's unrelated URL
# (redis://localhost:54321/0 -> redis://localhost:491871/0) instead of leaving it
# alone.
run_db_step job-prefix-port "${job_a[@]}" "DB_ENV=DATABASE_URL=postgres://app@localhost:5432/app_test
REDIS_URL=redis://localhost:54321/0
CACHE_URL=redis://localhost:5432a/0"
rc=$?
[ "$rc" -eq 0 ] || { echo "---- db step output ----"; cat "$tmp/job-prefix-port/out.txt"; }
{ grep -qF 'REDIS_URL=redis://localhost:54321/0' "$tmp/job-prefix-port/github_env" \
    && grep -qF 'CACHE_URL=redis://localhost:5432a/0' "$tmp/job-prefix-port/github_env" \
    && grep -qF 'DATABASE_URL=postgres://app@localhost:49187/app_test' "$tmp/job-prefix-port/github_env"; } \
  && pass "a port that merely starts with 5432 is left alone (the rewrite anchors on / ? or end)" \
  || fail "a 5432-prefixed port was mangled: $(grep -E '^(REDIS|CACHE)_URL=' "$tmp/job-prefix-port/github_env" | tr '\n' ' ')"

# Hardening: a rewrite MISS must be loud. Before the port became OS-assigned a
# missed rewrite was harmless — 5432 really was this job's container — but now an
# un-rewritten `:5432` points the caller's suite at whatever else listens on the
# host's 5432, which on a persistent self-hosted runner can be a real database
# that migrations would then truncate. An IPv6 literal host is a shape the URL
# rewrite cannot handle, so it must fail the step naming the key, not export a
# URL aimed at 5432.
run_db_step job-ipv6-host "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
DATABASE_URL=postgres://app@[::1]:5432/app_test"
rc=$?
{ [ "$rc" -ne 0 ] \
    && ! grep -q '^DATABASE_URL=.*:5432' "$tmp/job-ipv6-host/github_env" \
    && grep -qF 'DATABASE_URL' "$tmp/job-ipv6-host/out.txt"; } \
  && pass "a postgres:// value the rewrite cannot handle fails the step, naming the key" \
  || fail "step exited $rc and exported $(grep '^DATABASE_URL=' "$tmp/job-ipv6-host/github_env" || echo 'no URL') for an IPv6 host (a miss silently aims the suite at host port 5432)"

# Hardening: a password containing `@` is a legal URL (the userinfo runs to the
# LAST `@` before the path), and it is exactly the shape a generated test
# password takes. It must be rewritten like any other, not treated as a host.
run_db_step job-at-password "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
DATABASE_URL=postgres://app:p@ss@localhost:5432/app_test"
rc=$?
{ [ "$rc" -eq 0 ] \
    && grep -qF 'DATABASE_URL=postgres://app:p@ss@localhost:49187/app_test' "$tmp/job-at-password/github_env"; } \
  && pass "an @ in the db-env password still resolves the host port" \
  || fail "step exited $rc for an @-in-password URL: $(grep '^DATABASE_URL=' "$tmp/job-at-password/github_env" || echo '<absent>')"

# Hardening: shapes the URL rewrite does not cover must be rejected, not written
# through verbatim — each of these still names port 5432, which is now someone
# else's database on a shared host.
i=0
for shape in 'DATABASE_URL="postgres://app@localhost:5432/app_test"' \
             'DATABASE_URL=jdbc:postgresql://localhost:5432/app_test' \
             'DATABASE_URL=host=localhost port=5432 dbname=app' \
             'DATABASE_URL=postgres://app@localhost:54322/app_test'; do
  i=$((i + 1))
  run_db_step "job-shape-$i" "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
$shape"
  rc=$?
  { [ "$rc" -ne 0 ] && ! grep -q '5432' "$tmp/job-shape-$i/github_env"; } \
    && pass "an unrewritable db-env shape is rejected: ${shape%%=*}=${shape#*=}" \
    || fail "step exited $rc and exported $(grep '^DATABASE_URL=' "$tmp/job-shape-$i/github_env" || echo 'nothing') for: $shape"
done

# Hardening: PGHOST/PGPORT is the other standard way to point libpq at a
# database, and a caller writing PGPORT means "the service this step started" —
# so it must be pointed at the mapped port, not passed through at 5432.
run_db_step job-pgport "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
PGHOST=127.0.0.1
PGPORT=5432"
rc=$?
{ [ "$rc" -eq 0 ] \
    && grep -qF 'PGPORT=49187' "$tmp/job-pgport/github_env" \
    && grep -qF 'PGHOST=127.0.0.1' "$tmp/job-pgport/github_env"; } \
  && pass "a db-env PGPORT is pointed at the mapped port" \
  || fail "step exited $rc and exported $(grep '^PGPORT=' "$tmp/job-pgport/github_env" || echo 'no PGPORT')"

# Hardening: $GITHUB_ENV is last-wins, so a caller's own DB_PORT line — a
# plausible thing to write, since the step advertises $DB_PORT — must not
# overwrite the real mapped port for every later step.
run_db_step job-caller-dbport "${job_a[@]}" "DB_ENV=POSTGRES_USER=app
DB_PORT=5432"
rc=$?
{ [ "$rc" -eq 0 ] \
    && [ "$(grep -c '^DB_PORT=' "$tmp/job-caller-dbport/github_env")" -eq 1 ] \
    && [ "$(grep '^DB_PORT=' "$tmp/job-caller-dbport/github_env" | tail -n1)" = "DB_PORT=49187" ]; } \
  && pass "a caller-supplied DB_PORT cannot override the mapped port" \
  || fail "step exited $rc and left DB_PORT as: $(grep '^DB_PORT=' "$tmp/job-caller-dbport/github_env" | tr '\n' ' ')"

# Hardening: readiness is probed with pg_isready INSIDE the container, which says
# nothing about the loopback publish — the thing this change actually introduced.
# The step must also probe the mapped port from the host and say so when it is
# not accepting connections (port 9/discard stands in for a dead publish).
run_db_step job-hostprobe "${job_a[@]}" MAPPED_PORT=9
rc=$?
{ [ "$rc" -eq 0 ] && grep -qF '127.0.0.1:9' "$tmp/job-hostprobe/out.txt"; } \
  && pass "the step probes the mapped port from the host and reports it unreachable" \
  || fail "step exited $rc with no host-side reachability probe: $(cat "$tmp/job-hostprobe/out.txt")"

# Hardening: if the port can't be read back there is no usable connection at all,
# so the step must fail instead of exporting a URL pointing nowhere.
run_db_step job-noport "${job_a[@]}" MAPPED_PORT=
rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^DATABASE_URL=' "$tmp/job-noport/github_env"; } \
  && pass "an unreadable port mapping fails the step instead of exporting a dead URL" \
  || fail "step exited $rc and exported $(grep '^DATABASE_URL=' "$tmp/job-noport/github_env" || echo 'no URL') despite an unreadable port"

# ...and it must say WHY. An image that exits immediately dies on this branch,
# before the health loop's log dump, so without logs here the operator gets only
# "could not read the mapped host port" and no cause.
grep -q '^logs ' "$tmp/job-noport/docker.log" \
  && pass "an unreadable port mapping dumps the container's logs for diagnosis" \
  || fail "the port-read failure branch exits without dumping container logs: $(cat "$tmp/job-noport/out.txt")"

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

# (g) Teardown must remove the container the start step actually created, and the
# handle it consumes must be the ID docker assigned — not the name. The ID is
# unique by construction, so teardown can never reach another job's container
# even if the name's uniqueness premise fails; the name is kept for debugging.
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
teardown_handle_expr="$(awk '
  $0 == "      - name: Stop database service" { seen = 1; next }
  seen && $0 ~ /^      - name:/ { exit }
  seen && $0 ~ /^          CONTAINER_ID: / { sub(/^          CONTAINER_ID: /, ""); print; exit }
' "$wf")"
# Resolve the teardown env expression the way the runner would, from the start
# step's published outputs and the run context.
id_a="$(published_handle_of job-a)"
resolved_handle="$teardown_handle_expr"
resolved_handle="${resolved_handle//\$\{\{ steps.db-service.outputs.container-id \}\}/$id_a}"
resolved_handle="${resolved_handle//\$\{\{ github.run_id \}\}/$GITHUB_RUN_ID}"
resolved_handle="${resolved_handle//\$\{\{ github.run_attempt \}\}/$GITHUB_RUN_ATTEMPT}"
mkdir -p "$tmp/teardown"
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_ID="$resolved_handle" \
  bash "$teardown_script" >"$tmp/teardown/out.txt" 2>&1
{ [ -n "$id_a" ] && [ "$id_a" != "$name_a" ] && grep -qF -- "rm -f $id_a" "$tmp/teardown/docker.log"; } \
  && pass "teardown removes the container by the ID docker assigned, not by name" \
  || fail "teardown targeted '$resolved_handle' but the start step created container id '$id_a' (name '$name_a')"

# The start step must also drive `docker port`/`docker exec` off that same ID, so
# every operation after `docker run` is pinned to the container it created.
{ grep -qE "^port $id_a " "$tmp/job-a/docker.log" \
    && grep -qE "^exec $id_a " "$tmp/job-a/docker.log"; } \
  && pass "the start step reads the port and probes readiness via the container ID" \
  || fail "start step used a non-ID handle: $(grep -E '^(port|exec) ' "$tmp/job-a/docker.log" | tr '\n' ' ')"

# Hardening: a removal the daemon refuses must fail the teardown step. With an
# OS-assigned port a leaked container no longer breaks the next job's bind, so
# this is the only signal that one is squatting on the host.
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_ID="$resolved_handle" \
  RM_FAIL="Error response from daemon: cannot remove container: device or resource busy" \
  bash "$teardown_script" >"$tmp/teardown/out-rmfail.txt" 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && grep -qF 'device or resource busy' "$tmp/teardown/out-rmfail.txt"; } \
  && pass "teardown fails loudly when the container cannot be removed" \
  || fail "teardown exited $rc on a refused removal: $(cat "$tmp/teardown/out-rmfail.txt")"

# ...but a container that is already gone is not a failure: nothing is leaking.
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_ID="$resolved_handle" \
  RM_FAIL="Error: No such container: $resolved_handle" \
  bash "$teardown_script" >"$tmp/teardown/out-rmgone.txt" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "teardown tolerates a container that is already gone" \
  || fail "teardown exited $rc for an already-removed container: $(cat "$tmp/teardown/out-rmgone.txt")"

# Hardening: teardown also runs when the start step never reached `docker run`
# (its output is then empty) — it must be a no-op, not a `docker rm -f ""`.
: >"$tmp/teardown/docker.log"
env DOCKER_LOG="$tmp/teardown/docker.log" CONTAINER_ID="" \
  bash "$teardown_script" >"$tmp/teardown/out-empty.txt" 2>&1
[ ! -s "$tmp/teardown/docker.log" ] \
  && pass "teardown is a no-op when no container was started" \
  || fail "teardown called docker with no container id: $(cat "$tmp/teardown/docker.log")"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$fails test(s) failed."
  exit 1
fi
