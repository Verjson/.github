#!/usr/bin/env bash
# Configure the runner's git + npm credentials for a verJSON build.
#
# Split out of action.yml so the persistent-runner idempotency logic
# (Verjson/verjson-cli-cloud#59) is unit-testable without a live Actions runner.
# Reads its configuration from the environment:
#   NODE_AUTH_TOKEN    optional; re-exported for the job's later npm steps if set
#   VERJSON_GIT_TOKEN  optional; wires a git credential helper for private deps
#   GITHUB_ENV         path to the job's env file (a temp file under test)
set -uo pipefail

github_env="${GITHUB_ENV:-/dev/null}"

mask() {
  # ::add-mask:: only means something on a runner; harmless (and quiet) locally.
  [ -n "${1:-}" ] && printf '::add-mask::%s\n' "$1"
  return 0
}

# --- npm registry token -----------------------------------------------------
# setup-node writes an .npmrc that references ${NODE_AUTH_TOKEN} at install time;
# surface it to every later step in the job. It stays a masked secret.
if [ -n "${NODE_AUTH_TOKEN:-}" ]; then
  mask "${NODE_AUTH_TOKEN}"
  printf 'NODE_AUTH_TOKEN=%s\n' "${NODE_AUTH_TOKEN}" >>"${github_env}"
fi

# --- ssh->https rewrite (idempotent; survives the shared ~/.gitconfig) -------
# A plain `git config` set of a multi-valued key collides with entries a prior
# job left on the persistent runner ("cannot overwrite multiple values" — #59
# Gap 1), so reset with --unset-all before re-adding. Every branch below is
# idempotent and safe to re-run.
git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global --add url."https://github.com/".insteadOf "git@github.com:"

# --- git credential helper for private @verjson HTTPS deps ------------------
# Always reset first so a helper installed by a prior job on this runner cannot
# leak across builds; reinstall only when a token is supplied. The helper reads
# the token from the environment at clone time, so the secret itself never lands
# in the on-disk gitconfig — only the (non-secret) helper definition does.
git config --global --unset-all credential."https://github.com".helper 2>/dev/null || true
if [ -n "${VERJSON_GIT_TOKEN:-}" ]; then
  mask "${VERJSON_GIT_TOKEN}"
  printf 'VERJSON_GIT_TOKEN=%s\n' "${VERJSON_GIT_TOKEN}" >>"${github_env}"
  git config --global --add credential."https://github.com".helper \
    '!f() { echo "username=x-access-token"; echo "password=${VERJSON_GIT_TOKEN}"; }; f'
fi
