# Merge gate elides generated lockfiles from the AI review payload — 2026-07-22

The AI review lane fed the complete PR diff to the model, so a PR that touched
source **and** refreshed a lockfile spent its review budget reading the
generated lock (on `Verjson/verjson-ai#1`, `package-lock.json` was 8,007 of
10,559 added lines) and produced a no-verdict, fail-closed run. The
"Prepare bounded review context" step now writes the full diff to
`pr.full.diff` and hands the model a `pr.diff` with lockfile sections filtered
out, plus a prompt note naming the omitted locks so the manifest counterpart is
still reviewed. Lockfiles only are elided; manifests (`package.json`,
`Cargo.toml`, `Dockerfile`, …) are kept. Pinned by
`scripts/ci-gate/elide-lockfiles.test.sh` (wired into `actions-ci`). See
[ADR 0018](docs/decisions/0018-gate-elides-lockfiles-from-review/README.md),
issue #110.
