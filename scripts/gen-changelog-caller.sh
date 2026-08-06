#!/usr/bin/env bash
# Generate a consumer's changelog contract adoption files.
#
# Generated, not hand-written, because the two halves must agree on one commit
# and nothing fails loudly when they don't: the renderer keeps rendering, the
# workflow keeps validating, and local output silently stops predicting CI.
# Hand-writing this three times already produced three shapes.
#
# Usage:
#   scripts/gen-changelog-caller.sh workflow <sha> > .github/workflows/changelog.yml
#   scripts/gen-changelog-caller.sh renderer <sha> > scripts/render-next.sh
#   scripts/gen-changelog-caller.sh contract-test <sha> > scripts/changelog-contract.test.sh
#
# Consumers pin an immutable commit (docs/changelog/README.md) rather than a
# branch: the contract defines their release history's shape, so it must not
# move under them between a local render and the CI run that gates the PR.
#
# The contract test is generated for a second reason on top of pin agreement: it
# is the only adopter file that encodes assumptions about repository *state*, and
# every hand-copied version so far asserted a pre-release tree — named fragment
# titles, hashed released entries, "no CHANGELOG.md yet" — which the first real
# release deletes. Consumers wire it into `npm test`, which release workflows run
# before publishing, so that shape aborts the release it is supposed to protect.
# See #309.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") {workflow|renderer|contract-test} <40-hex-commit>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
mode="$1"
ref="$2"

# Strictly validated, not merely quoted. Both outputs interpolate this value —
# one into YAML, one into a shell assignment — so anything other than a bare
# commit is an injection vector. The sibling gen-privileged-merge-caller.sh
# documents a live instance of exactly that class.
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || {
  echo "$(basename "$0"): ref must be a 40-character lowercase commit SHA" >&2
  exit 2
}

# The digest of the engine at the pinned commit. Resolved here, once, so every
# generated script can verify what it is about to execute instead of trusting a
# path. Local object first (the usual case: generating from a checkout that has
# the ref), then the same URL the generated scripts use. No digest, no output —
# emitting an unverifiable contract would be worse than emitting nothing.
# Piped, never captured. `$(...)` strips trailing newlines, so hashing a captured
# copy digests content the file does not have — every honest override would then
# be rejected as divergent. Caught by the byte-identical-copy case in
# changelog-contract-resolution.test.sh, which is why that case exists.
resolve_contract_digest() {
  local out
  if out="$(git -C "$(dirname "$0")/.." show "$ref:scripts/changelog.py" 2>/dev/null | digest_of)" \
    && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  if out="$(curl -fsSL "https://raw.githubusercontent.com/Verjson/.github/$ref/scripts/changelog.py" 2>/dev/null | digest_of)" \
    && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# sha256sum on Linux, shasum on macOS. A host with neither cannot verify, and an
# unverified contract is not a contract.
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    return 1
  fi
}

contract_sha256="$(resolve_contract_digest)" || {
  echo "$(basename "$0"): cannot resolve the contract digest at $ref" >&2
  exit 1
}
[[ "$contract_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "$(basename "$0"): resolved digest is not a sha256: $contract_sha256" >&2
  exit 1
}

# The one place that decides which implementation runs. Emitted verbatim into
# both the renderer and the contract test: two copies of this logic is the drift
# #304 was filed about, one level down.
#
# Callers define contract_fail() and have $CONTRACT_REF and $CONTRACT_SHA256 in
# scope; this sets $contract.
emit_contract_resolution() {
  cat <<'EOF'

contract_digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 <"$1" | cut -d' ' -f1
  else
    return 1
  fi
}

# Identity, not existence. The cache path is keyed by commit, which reads as
# content-addressed but is not: nothing stops another tool, a restored CI cache,
# or an interrupted write from leaving different bytes there, and they would then
# be executed as the contract on every run.
contract_is_pinned() {
  [ -f "$1" ] || return 1
  local got
  got="$(contract_digest_of "$1")" || return 1
  [ "$got" = "$CONTRACT_SHA256" ]
}

# CHANGELOG_CONTRACT_PATH selects WHERE the engine comes from — a vendored copy,
# an offline mirror, a warmed CI cache — and cannot select WHAT runs, because the
# override is held to the digest pinned at $CONTRACT_REF. So it stays useful to
# an air-gapped or cache-restoring consumer while the guarantee the renderer is
# sold on ("the same code CI validates with") holds unconditionally (#304).
if [ -n "${CHANGELOG_CONTRACT_PATH:-}" ]; then
  contract="$CHANGELOG_CONTRACT_PATH"
  [ -e "$contract" ] \
    || contract_fail "CHANGELOG_CONTRACT_PATH is $contract, which does not exist"
  contract_is_pinned "$contract" \
    || contract_fail "CHANGELOG_CONTRACT_PATH ($contract) is not the contract pinned at $CONTRACT_REF"
else
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/verjson-changelog/$CONTRACT_REF"
  contract="$cache_dir/changelog.py"
  if ! contract_is_pinned "$contract"; then
    mkdir -p "$cache_dir"
    # mktemp, not a fixed name: concurrent runs share this cache directory.
    tmp="$(mktemp "$cache_dir/.changelog.XXXXXX")"
    if ! curl -fsSL \
      "https://raw.githubusercontent.com/Verjson/.github/$CONTRACT_REF/scripts/changelog.py" \
      -o "$tmp"; then
      rm -f "$tmp"
      contract_fail "cannot fetch the changelog contract at $CONTRACT_REF"
    fi
    # Verify before publishing into the cache, so a bad fetch is never persisted
    # for the next run to trust.
    if ! contract_is_pinned "$tmp"; then
      rm -f "$tmp"
      contract_fail "fetched contract does not match the digest pinned at $CONTRACT_REF"
    fi
    mv "$tmp" "$contract"
  fi
fi
EOF
}

emit_workflow() {
  cat <<EOF
name: changelog

on:
  pull_request:

permissions:
  contents: read

jobs:
  changelog:
    uses: Verjson/.github/.github/workflows/changelog-validate.yml@${ref}
    with:
      contract_ref: ${ref}
EOF
}

emit_renderer() {
  cat <<EOF
#!/usr/bin/env bash
# Prints the running log from the NEXT/ changelog fragments, newest first.
#
# Generated by Verjson/.github scripts/gen-changelog-caller.sh — do not edit by
# hand. Rendering is not implemented here: the canonical changelog contract
# lives in Verjson/.github (ADR 0038) and this repository pins one immutable
# commit of it, shared with .github/workflows/changelog.yml so that what you
# render locally is what CI validates.
set -euo pipefail

CONTRACT_REF="${ref}"
CONTRACT_SHA256="${contract_sha256}"

# --as-released is the only flag that passes through. It shows what a release
# would write into CHANGELOG/<version>.md, which under ADR 0059 can never be
# edited afterwards — so reading it before merge is the one review step the
# contract asks of a fragment author, and it has to be reachable from the tool
# they are given (#443). Everything else is still refused: this is a renderer,
# not a general front end to a pinned engine.
as_released=
if [ "\$#" -gt 0 ]; then
  if [ "\$#" -eq 1 ] && [ "\$1" = --as-released ]; then
    as_released=--as-released
  else
    echo "render-next: unexpected argument '\$1' (only --as-released is accepted)" >&2
    exit 2
  fi
fi

root="\$(cd "\$(dirname "\$0")/.." && pwd)"

contract_fail() { echo "render-next: \$1" >&2; exit 1; }
EOF
  emit_contract_resolution
  cat <<EOF

if [ -n "\$as_released" ]; then
  exec python3 "\$contract" render-next --repo-root "\$root" --as-released
fi
exec python3 "\$contract" render-next --repo-root "\$root"
EOF
}

emit_contract_test() {
  # The interpolated preamble is kept deliberately small: everything below it is
  # a quoted heredoc, so the body cannot accidentally expand a generator-side
  # variable into an adopter's test.
  cat <<EOF
#!/usr/bin/env bash
# Asserts that this repository still satisfies the canonical Verjson changelog
# contract (Verjson/.github ADR 0038) rather than a local re-implementation of it.
#
# Generated by Verjson/.github scripts/gen-changelog-caller.sh — do not edit by
# hand. Regenerate it whenever the pinned contract commit moves, together with
# .github/workflows/changelog.yml and scripts/render-next.sh.
#
# Every assertion here holds both BEFORE and AFTER a release. \`release\` consumes
# NEXT/, writes CHANGELOG/<version>.md and generates the root CHANGELOG.md, so an
# assertion phrased as "nothing has been released yet" is a time bomb: consumers
# wire this suite into \`npm test\`, which release workflows run before publishing,
# so it would abort the release it exists to protect. Assertions about repository
# content are therefore derived from the tree, never named inline.
set -euo pipefail

CONTRACT_REF="${ref}"
CONTRACT_SHA256="${contract_sha256}"
EOF
  cat <<'EOF'

root="$(cd "$(dirname "$0")/.." && pwd)"
renderer="$root/scripts/render-next.sh"
validation_workflow="$root/.github/workflows/changelog.yml"
release_workflow="$root/.github/workflows/release.yml"

fail() { echo "FAIL - $1" >&2; exit 1; }

contract_fail() { fail "$1"; }
EOF
  emit_contract_resolution
  cat <<'EOF' 

work="$(mktemp -d)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$work" "$fixture_root"' EXIT

python3 "$contract" validate --repo-root "$root"
echo "ok - canonical validation accepts this repository"

# One pin, shared by every generated artifact: local rendering must predict the
# CI run that gates the PR, and the release must write the shape both assumed.
grep -q "changelog-validate.yml@$CONTRACT_REF" "$validation_workflow" \
  || fail "$validation_workflow does not call the validation workflow at the pin"
grep -q "contract_ref: $CONTRACT_REF" "$validation_workflow" \
  || fail "$validation_workflow does not pass the pinned contract_ref"
grep -q "CONTRACT_REF=\"$CONTRACT_REF\"" "$renderer" \
  || fail "$renderer does not pin the same contract commit"
if [ -f "$release_workflow" ]; then
  grep -q "changelog-release.yml@$CONTRACT_REF" "$release_workflow" \
    || fail "$release_workflow does not call the release workflow at the pin"
  # The release pushes its snapshot commit and tag straight to the default
  # branch, which the standard Verjson `main-protection` ruleset forbids for
  # every actor outside its bypass list. GITHUB_TOKEN is not on that list, so a
  # caller wiring it is rejected by GH013 at the last step of the last job —
  # past everything a pull request or a remote-less fixture can observe. Pass an
  # admin-scoped secret instead (Verjson/.github ADR 0052).
  #
  # The value is isolated before matching rather than grepped for inline. A
  # guard on the raw line misses every ordinary spelling of the same wiring —
  # a quoted scalar, the `github.token` alias, the case-insensitive
  # `secrets.github_token`, a folded value on the following line — and each
  # miss reports green while reproducing the failure exactly. It also fires on
  # a `# NOT GITHUB_TOKEN` comment sitting above a correct wiring, which is a
  # comment this contract's own documentation recommends writing.
  push_token_value="$(sed 's/#.*//' "$release_workflow" | awk '
    /^[[:space:]]*push_token:/ { depth = match($0, /[^[:space:]]/); found = 1; print; next }
    found && $0 ~ /^[[:space:]]*$/ { next }
    found && match($0, /[^[:space:]]/) > depth { print; next }
    found { found = 0 }
  ')"
  if printf '%s\n' "$push_token_value" \
    | grep -qiE '\$\{\{[[:space:]]*(secrets\.GITHUB_TOKEN|github\.token)[[:space:]]*\}\}'; then
    fail "$release_workflow passes GITHUB_TOKEN as push_token; the branch ruleset rejects that push. Pass an admin-scoped secret."
  fi
fi
echo "ok - render, validation and release automation share one immutable pin"

# The regression this file exists to prevent was a hand-written local renderer
# that kept working while silently diverging from the contract.
grep -q 'gen-changelog-caller.sh' "$renderer" \
  || fail "$renderer is not the generated renderer; regenerate it"
echo "ok - the renderer delegates to the contract instead of reimplementing it"

# A non-executable script fails CI with exit 126 long after the diff looks fine.
for file in "$renderer" "$0"; do
  [ -x "$file" ] || fail "$file is not executable"
done
echo "ok - contract scripts are executable"

# Guarded, because render-next exits non-zero on an empty NEXT/ — which is
# exactly the state a release leaves behind. The final fixture proves this guard
# is still load-bearing rather than dead code.
#
# The rendered log travels through a file, never through a variable handed to
# execve. A single argv or environment string is capped at MAX_ARG_STRLEN — a
# fixed 128 KiB, unrelated to the far larger ARG_MAX that a check would read —
# so an adopter whose unreleased NEXT/ crossed that line died here with a bare
# "Argument list too long" and exit 126, naming neither the changelog nor the
# fragment count (#398). NEXT/ is per-change and never batched, so it grows past
# 128 KiB in the ordinary course of a busy release cycle; releasing consumes it,
# but the release path runs this suite, so the failure gated its own remedy.
if "$renderer" >"$work/rendered" 2>/dev/null; then
  ROOT="$root" RENDERED_PATH="$work/rendered" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(os.environ["ROOT"])
rendered = Path(os.environ["RENDERED_PATH"]).read_text(encoding="utf-8")
# 0000-archive.md is special-cased by name and is not rendered in strict mode.
skip = {"README.md", "0000-archive.md"}
fragments = sorted(p for p in (root / "NEXT").glob("*.md") if p.name not in skip)
if not fragments:
    sys.exit("NEXT/ holds no renderable fragments but the renderer produced output")

def unquote(value):
    """The text a YAML-quoted scalar denotes.

    Reimplemented rather than imported, deliberately: this file exists to check
    the engine's output, so it must not borrow the engine's reading of the
    input. But it does have to read the same subset. YAML *requires* a quoted
    scalar wherever a value contains `: `, which is the shape of every
    conventional-commit title, so a parser that keeps the quotes as literal text
    rejects the one spelling a YAML parser accepts and reports it as a missing
    title. A value that merely opens and closes with a quote is not a quoted
    scalar and is returned untouched.
    """
    if len(value) < 2 or value[0] not in "'\"" or value[-1] != value[0]:
        return value
    quote, inner = value[0], value[1:-1]
    index = 0
    while index < len(inner):
        if quote == '"' and inner[index] == "\\":
            index += 2
            continue
        if inner[index] == quote:
            if quote == "'" and inner[index : index + 2] == "''":
                index += 2
                continue
            return value
        index += 1
    if quote == "'":
        return inner.replace("''", "'")
    return inner.replace('\\"', '"').replace("\\\\", "\\")


for path in fragments:
    front = path.read_text(encoding="utf-8").split("---", 2)[1]
    meta = {}
    for line in front.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta[key.strip()] = unquote(value.strip())
    if f"## {meta['title']}" not in rendered:
        sys.exit(f"{path.name}: title missing from the rendered log")
    # Identity is not decoration: only issue-form entries render a `#n`
    # back-link, so a fragment demoted to `id` silently loses release linkage
    # and no validation error is raised.
    if "issue" in meta:
        pattern = rf"^_Date: {re.escape(meta['date'])}; issue #{re.escape(meta['issue'])}_$"
        if not re.search(pattern, rendered, re.MULTILINE):
            sys.exit(f"{path.name}: issue back-link missing from the rendered log")

# Metadata, not filename allocation, orders the log.
dates = re.findall(r"^_Date: (\d{4}-\d{2}-\d{2});", rendered, re.MULTILINE)
if dates != sorted(dates, reverse=True):
    sys.exit("rendered log is not newest-first by metadata date")
PY
  echo "ok - every unreleased fragment renders with its metadata linkage, newest first"
else
  echo "ok - no unreleased fragments to render (a release consumed them)"
fi

# CHANGELOG.md is generated by `release`, never authored. Asserting it absent
# fails the moment the contract works as intended, so assert instead that it is
# exactly what the released snapshots render to.
if [ -e "$root/CHANGELOG.md" ]; then
  python3 "$contract" render-released --repo-root "$root" >"$work/released"
  diff -q "$work/released" "$root/CHANGELOG.md" >/dev/null \
    || fail "CHANGELOG.md was hand-edited; it must equal the rendered released snapshots"
  echo "ok - CHANGELOG.md is generated from released snapshots, not authored"
else
  echo "ok - no aggregate changelog yet; nothing has been released"
fi

# A root NEXT.md may survive as a pointer, but never as a second running log:
# entries written there are invisible to validation, rendering and release.
if [ -e "$root/NEXT.md" ] && grep -q '^## ' "$root/NEXT.md"; then
  fail "NEXT.md still holds log entries; NEXT/ is the only unreleased store"
fi
echo "ok - NEXT/ is the only unreleased store"

# Releases are the only writer of released history. A stray .releaserc.json
# silently reintroduces release-on-merge, which never consumes a fragment.
[ ! -e "$root/.releaserc.json" ] \
  || fail ".releaserc.json reintroduces semantic-release outside the contract"
if [ -f "$release_workflow" ]; then
  grep -q 'workflow_dispatch' "$release_workflow" \
    || fail "$release_workflow is not dispatched explicitly"
fi
echo "ok - releases are dispatched explicitly, not derived from pushes to main"

new_fixture() {
  rm -rf "$fixture_root/case"
  mkdir -p "$fixture_root/case/NEXT"
}

write_fragment() {
  # write_fragment <relative-path> <date> <identity-line> <title>
  cat >"$fixture_root/case/$1" <<FRAGMENT
---
date: $2
$3
title: $4
---

Body.
FRAGMENT
}

init_fixture_repo() {
  git -C "$fixture_root/case" init -q
  git -C "$fixture_root/case" config user.name Test
  git -C "$fixture_root/case" config user.email test@example.com
}

# The rules this repository relies on, exercised against the pinned contract so
# that re-pinning to a revision that dropped one fails here rather than in a
# release six weeks later.
new_fixture
for slug in first second; do
  write_fragment "NEXT/2026-08-01-issue-43-$slug.md" 2026-08-01 "issue: 43" Duplicate
done
if python3 "$contract" validate --repo-root "$fixture_root/case" 2>"$fixture_root/error"; then
  fail "duplicate issue identity was accepted"
fi
grep -q 'duplicate identity issue:43' "$fixture_root/error"
echo "ok - duplicate issue identities are rejected"

new_fixture
write_fragment NEXT/2026-08-01-issue-43-wrong-date.md 2026-07-31 "issue: 43" "Wrong date"
if python3 "$contract" validate --repo-root "$fixture_root/case" 2>"$fixture_root/error"; then
  fail "mismatched filename metadata was accepted"
fi
grep -q 'does not match' "$fixture_root/error"
echo "ok - filename and metadata must agree"

new_fixture
printf '# Legacy entry\n\nBody.\n' >"$fixture_root/case/NEXT/2026-08-01-legacy.md"
if python3 "$contract" validate --repo-root "$fixture_root/case" 2>"$fixture_root/error"; then
  fail "a pre-contract fragment name was accepted"
fi
grep -q 'does not follow the canonical contract' "$fixture_root/error"
echo "ok - pre-contract fragment names are rejected"

new_fixture
write_fragment NEXT/2026-07-31-issue-99-zzz.md 2026-07-31 "issue: 99" Older
write_fragment NEXT/2026-08-01-issue-1-aaa.md 2026-08-01 "issue: 1" Newer
ordered="$(python3 "$contract" render-next --repo-root "$fixture_root/case")"
[ "$(grep -n '^## Newer$' <<<"$ordered" | cut -d: -f1)" \
  -lt "$(grep -n '^## Older$' <<<"$ordered" | cut -d: -f1)" ] \
  || fail "rendering order followed slug allocation instead of metadata"
echo "ok - rendering order follows metadata instead of slug allocation"

# Issue-less work keeps the literal -issue- filename segment; only the identity
# varies. A -id- filename is rejected even though the metadata key is `id`.
new_fixture
write_fragment NEXT/2026-08-01-issue-20260801T184500Z-timestamped.md \
  2026-08-01 "id: 20260801T184500Z" "Issue-less work"
python3 "$contract" validate --repo-root "$fixture_root/case"
echo "ok - issue-less work may use a UTC timestamp identity"

# ADR 0017's check-pr rule, both halves: an ordinary pull request may neither
# write released history nor consume a fragment.
new_fixture
init_fixture_repo
write_fragment NEXT/2026-08-01-issue-43-base.md 2026-08-01 "issue: 43" Base
git -C "$fixture_root/case" add .
git -C "$fixture_root/case" commit -qm base
base="$(git -C "$fixture_root/case" rev-parse HEAD)"
mkdir -p "$fixture_root/case/CHANGELOG"
printf 'snapshot\n' >"$fixture_root/case/CHANGELOG/v9.9.9.md"
git -C "$fixture_root/case" add .
git -C "$fixture_root/case" commit -qm "write released history"
if python3 "$contract" check-pr --repo-root "$fixture_root/case" \
  --base "$base" --head HEAD 2>"$fixture_root/error"; then
  fail "a pull request writing released history was accepted"
fi
grep -q 'released snapshots' "$fixture_root/error"
echo "ok - pull requests cannot write released history"

new_fixture
init_fixture_repo
write_fragment NEXT/2026-08-01-issue-43-base.md 2026-08-01 "issue: 43" Base
git -C "$fixture_root/case" add .
git -C "$fixture_root/case" commit -qm base
base="$(git -C "$fixture_root/case" rev-parse HEAD)"
git -C "$fixture_root/case" rm -q "NEXT/2026-08-01-issue-43-base.md"
git -C "$fixture_root/case" commit -qm "consume a fragment"
if python3 "$contract" check-pr --repo-root "$fixture_root/case" \
  --base "$base" --head HEAD 2>"$fixture_root/error"; then
  fail "a pull request deleting a NEXT/ fragment was accepted"
fi
grep -q 'NEXT' "$fixture_root/error"
echo "ok - pull requests cannot consume NEXT/ fragments"

new_fixture
init_fixture_repo
mkdir -p "$fixture_root/case/CHANGELOG"
write_fragment NEXT/2026-08-01-issue-43-release.md 2026-08-01 "issue: 43" Release
printf 'immutable\n' >"$fixture_root/case/CHANGELOG/v1.0.0.md"
git -C "$fixture_root/case" add .
git -C "$fixture_root/case" commit -qm initial
if python3 "$contract" release --repo-root "$fixture_root/case" --version v1.0.0 \
  2>"$fixture_root/error"; then
  fail "a released snapshot overwrite was accepted"
fi
grep -q 'already exists' "$fixture_root/error"
[ "$(cat "$fixture_root/case/CHANGELOG/v1.0.0.md")" = 'immutable' ] \
  || fail "a rejected release still mutated the snapshot"
echo "ok - released snapshots cannot be overwritten"

# The regression this file exists to prevent: prove that the repository-level
# assertions above survive a real release, instead of asserting a pre-release
# state that the first tag destroys. Every branch taken above is taken again
# here against a released tree.
new_fixture
init_fixture_repo
write_fragment NEXT/2026-08-01-issue-43-released.md 2026-08-01 "issue: 43" Released
git -C "$fixture_root/case" add .
git -C "$fixture_root/case" commit -qm initial
python3 "$contract" release --repo-root "$fixture_root/case" --version v1.0.0 >/dev/null
[ -f "$fixture_root/case/CHANGELOG/v1.0.0.md" ] || fail "release wrote no snapshot"
[ -e "$fixture_root/case/CHANGELOG.md" ] || fail "release generated no aggregate changelog"
[ -z "$(ls -1 "$fixture_root/case/NEXT" 2>/dev/null)" ] \
  || fail "release left fragments behind in NEXT/"
python3 "$contract" render-released --repo-root "$fixture_root/case" >"$work/after"
diff -q "$work/after" "$fixture_root/case/CHANGELOG.md" >/dev/null \
  || fail "the generated CHANGELOG.md does not equal the rendered released snapshots"
# If this ever succeeds, the guard around the render block above is dead code and
# a future edit could reintroduce the unguarded form without any test failing.
if python3 "$contract" render-next --repo-root "$fixture_root/case" >/dev/null 2>&1; then
  fail "render-next succeeded on an emptied NEXT/; the guard above is now dead code"
fi
echo "ok - a real release produces exactly the state asserted above"
EOF
}

# Never hand an operator a file that does not parse. The premise of generating
# these at all is that they should not be able to receive a silent footgun.
case "$mode" in
  workflow)
    out="$(emit_workflow)"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
      printf '%s\n' "$out" | python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' 2>/dev/null \
        || { echo "internal error: generated workflow is not valid YAML; refusing to emit" >&2; exit 3; }
    fi
    ;;
  renderer)
    out="$(emit_renderer)"
    printf '%s\n' "$out" | bash -n 2>/dev/null \
      || { echo "internal error: generated renderer is not valid bash; refusing to emit" >&2; exit 3; }
    ;;
  contract-test)
    out="$(emit_contract_test)"
    printf '%s\n' "$out" | bash -n 2>/dev/null \
      || { echo "internal error: generated contract test is not valid bash; refusing to emit" >&2; exit 3; }
    ;;
  *)
    usage
    ;;
esac
printf '%s\n' "$out"
