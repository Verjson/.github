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
#   scripts/gen-changelog-caller.sh release-node <sha> > .github/workflows/release.yml
#
# `release-node` is the fourth output and the newest. It was added because the
# release caller was the one adopter file still hand-copied from a sibling, and
# every defect in the copied shape propagated to every migrated repository at
# once: verification running after the irreversible snapshot (#463, #464),
# `npm ci` installing with GITHUB_TOKEN (#465), and the two halves of one release
# landing on two runner pools (#465). Adopters with nothing to publish keep
# having no release caller at all; that is still a supported shape.
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
  echo "usage: $(basename "$0") {workflow|renderer|contract-test|release-node} <40-hex-commit>" >&2
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

# One runner expression, emitted verbatim into every position that routes a job
# in the release caller. #465(2): a caller that omits the optional `runner:`
# input lets changelog-release.yml route the snapshot through
# VERJSON_RUNNER_OVERFLOW (hosted for a private Verjson repository) while the
# caller's own jobs hardcode an expression resolving to VERJSON_RUNNER_DEFAULT
# (self-hosted). One release then runs its two halves on two pools, and on a
# private repository without hosted minutes the snapshot half — the half that
# mutates ruleset-protected `main` — queues silently: no check run, no error, no
# signal. Substituted from a single variable so the three occurrences cannot
# drift; the generated contract test asserts they are still identical.
release_runner_expr="github.repository_owner == 'Verjson' && (vars.VERJSON_RUNNER_DEFAULT || '[\"self-hosted\",\"general\"]') || '[\"ubuntu-24.04\"]'"

# The audited action commits this repository pins everywhere else
# (scripts/node-workflow-pins.test.sh).
release_checkout='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7'
release_setup_node='actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7'

emit_release_node() {
  cat <<EOF
name: Release

# Generated by Verjson/.github scripts/gen-changelog-caller.sh release-node ${ref}
# — do not edit by hand. Regenerate it whenever the pinned contract commit moves,
# together with .github/workflows/changelog.yml, scripts/render-next.sh and
# scripts/changelog-contract.test.sh. A partial regeneration is the divergence
# the generator exists to prevent.
#
# WHY THE JOB ORDER IS THE POINT OF THIS FILE (Verjson/.github #463, #464, #465)
#
# \`snapshot\` calls changelog-release.yml, which consumes the NEXT/ fragments,
# writes an immutable CHANGELOG/<version>.md, commits, tags, and pushes all of it
# to the default branch in ONE atomic push. Nothing after that push can be undone
# by re-running: the same version is refused because the tag exists, and a higher
# version is refused with "release selected no fragments" because NEXT/ was
# already consumed. Recovery is manual surgery on a ruleset-protected branch.
#
# So every check that can say "no" runs in \`verify\`, which \`snapshot\` declares in
# \`needs:\` — dispatched-from-the-default-branch, version format, tag absence, and
# the repository's full suite.
#
# \`verify\` checks out \`github.sha\` — the dispatch commit — and
# changelog-release.yml checks out that same commit instead of re-resolving the
# branch name at snapshot time. Both halves must pin it: pinning only one leaves
# the window in which anything merged mid-run is tagged without ever being
# verified. Because the snapshot is taken from the dispatch commit, its final
# --atomic push is non-fast-forward if the default branch has moved since, so a
# concurrent merge fails the release with no tag pushed and every NEXT/ fragment
# still unconsumed — re-dispatch from the new head.
#
# What \`verify\` cannot check is the snapshot commit itself: it does not exist
# yet. Verifying the dispatch commit stands in for it because of what that commit
# contains — a clean-checkout run of the pinned scripts/changelog.py release
# produces a commit whose diff is exactly CHANGELOG.md, CHANGELOG/<version>.md
# and the consumed NEXT/ fragments, touching no source, no config and no
# dependency. So the tree \`publish\` builds from the tag is byte-for-byte the tree
# \`verify\` proved, minus the changelog.
#
# HOW TO CONFIGURE THE SUITE WITHOUT EDITING THIS FILE
#
# If your suite is not \`npm test\`, commit an executable \`scripts/release-verify.sh\`
# and \`verify\` runs it instead of the default Node sequence. The escape hatch is a
# separate file you own precisely so that no adopter has to edit a generated
# artifact — an artifact adopters must edit is the defect this generator removes,
# not a compromise it makes.
#
# Dispatched, never derived. A release states the version it cuts; no push
# trigger may infer one from commit subjects (ADR 0038, ADR 0060).

on:
  workflow_dispatch:
    inputs:
      version:
        description: Exact next SemVer tag, including the v prefix
        required: true
        type: string
      fragments:
        description: Newline-separated NEXT fragment filenames; empty selects all
        required: false
        type: string
        default: ''

permissions:
  contents: read

jobs:
  verify:
    name: Verify the tree the snapshot will tag
    runs-on: \${{ fromJSON(${release_runner_expr}) }}
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
      # changelog-release.yml carries this guard too, but there it fires inside
      # \`snapshot\` — after \`verify\` has already spent a full suite run on a ref
      # whose tree will never be tagged. It is asserted here first because
      # verifying any ref other than the default branch proves nothing about the
      # content the snapshot takes (#466).
      - name: Release only from the default branch
        env:
          DISPATCH_REF: \${{ github.ref }}
          DEFAULT_BRANCH: \${{ github.event.repository.default_branch }}
        run: |
          if [ "\$DISPATCH_REF" != "refs/heads/\$DEFAULT_BRANCH" ]; then
            echo "::error::A release must be dispatched from \$DEFAULT_BRANCH, but this run was dispatched from '\$DISPATCH_REF'. The snapshot is always taken from \$DEFAULT_BRANCH, so verifying any other ref proves nothing about the tree that would be tagged."
            exit 1
          fi
          echo "Dispatched from \$DEFAULT_BRANCH; verifying its head."
      - name: Require an exact v-prefixed SemVer version
        env:
          VERSION: \${{ inputs.version }}
        run: |
          if [[ ! "\$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\$ ]]; then
            echo "::error::'\$VERSION' is not an exact v-prefixed SemVer tag. The engine strips a leading v, so a bare '1.2.3' cuts a bare tag and a CHANGELOG/1.2.3.md that sort apart from every v-prefixed sibling — and nothing downstream rejects it."
            exit 1
          fi
          echo "Cutting \$VERSION."
      - name: Check out the tree that will be released
        uses: ${release_checkout}
        with:
          # github.sha is the default branch head at dispatch time, and
          # changelog-release.yml checks out that same commit rather than
          # re-resolving the branch name at snapshot time — so the tree verified
          # here is the tree that gets tagged, even if something merges to the
          # default branch while this job is running. Both halves must agree:
          # pinning only one of them reintroduces the window (#463, #464).
          ref: \${{ github.sha }}
          fetch-depth: 0
      - name: Refuse a version that has already been released
        env:
          VERSION: \${{ inputs.version }}
        run: |
          if git ls-remote --exit-code --tags origin "refs/tags/\$VERSION" >/dev/null 2>&1; then
            echo "::error::Tag \$VERSION already exists. The snapshot push is --atomic and would be rejected after the suite had run; cut the next version instead."
            exit 1
          fi
          if [ -e "CHANGELOG/\$VERSION.md" ]; then
            echo "::error::CHANGELOG/\$VERSION.md already exists, and a released snapshot is immutable (ADR 0059). Cut the next version instead."
            exit 1
          fi
          echo "\$VERSION is unused."
      - uses: ${release_setup_node}
        with:
          node-version: '24'
          registry-url: https://npm.pkg.github.com
          scope: '@verjson'
          package-manager-cache: false
      - name: Install dependencies
        run: npm ci
        env:
          # NOT GITHUB_TOKEN (#465). A repository-scoped GITHUB_TOKEN cannot read
          # a private GitHub Packages package owned by a DIFFERENT repository, so
          # an adopter with a private @verjson devDependency 401s here. Canonical
          # node-ci.yml states the same requirement for the same reason.
          NODE_AUTH_TOKEN: \${{ secrets.NODE_AUTH_TOKEN }}
      - name: Run the release verification suite
        run: |
          # Existence and executability are checked separately on purpose. A
          # single \`-x\` test reads a hook committed without the executable bit
          # as "no hook here" and quietly runs the Node default instead — so an
          # adopter who deliberately replaced their suite watches a green
          # release verified by the suite they replaced.
          if [ -e scripts/release-verify.sh ] && [ ! -x scripts/release-verify.sh ]; then
            echo "::error::scripts/release-verify.sh exists but is not executable, so this release would silently fall back to the default Node suite. Run: chmod +x scripts/release-verify.sh && git update-index --chmod=+x scripts/release-verify.sh"
            exit 1
          fi
          if [ -x scripts/release-verify.sh ]; then
            echo "Running this repository's scripts/release-verify.sh"
            exec scripts/release-verify.sh
          fi
          npm run build --if-present
          npm run typecheck --if-present
          npm run lint --if-present
          npm test

  snapshot:
    # The irreversible act, and the only job that may not run first.
    needs: verify
    uses: Verjson/.github/.github/workflows/changelog-release.yml@${ref}
    permissions:
      contents: write
    with:
      contract_ref: ${ref}
      version: \${{ inputs.version }}
      fragments: \${{ inputs.fragments }}
      # Explicit, so both halves of one release share one pool (#465).
      runner: \${{ ${release_runner_expr} }}
    secrets:
      # NOT GITHUB_TOKEN — see Verjson/.github ADR 0052. The push targets the
      # default branch, which the standard main-protection ruleset forbids for
      # every actor outside its bypass list.
      push_token: \${{ secrets.ORG_ADMIN_TOKEN }}

  publish:
    name: Publish the released snapshot
    needs: snapshot
    runs-on: \${{ fromJSON(${release_runner_expr}) }}
    timeout-minutes: 30
    permissions:
      contents: write
      packages: write
    steps:
      - name: Check out the release tag
        uses: ${release_checkout}
        with:
          ref: \${{ inputs.version }}
          fetch-depth: 0
      - uses: ${release_setup_node}
        with:
          node-version: '24'
          registry-url: https://npm.pkg.github.com
          scope: '@verjson'
          package-manager-cache: false
      - name: Install dependencies
        run: npm ci
        env:
          # NOT GITHUB_TOKEN, for the same reason as in verify (#465).
          NODE_AUTH_TOKEN: \${{ secrets.NODE_AUTH_TOKEN }}
      - run: npm run build --if-present
      - name: Publish the exact snapshot version
        env:
          # GITHUB_TOKEN is correct here, and only here: publishing this
          # repository's own package to its own GitHub Packages registry is
          # exactly what a repository-scoped token is for.
          NODE_AUTH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          VERSION: \${{ inputs.version }}
        run: |
          npm version "\${VERSION#v}" --no-git-tag-version
          npm publish
      - name: Publish the snapshot release notes
        env:
          GH_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          VERSION: \${{ inputs.version }}
        run: gh release create "\$VERSION" --verify-tag --notes-file "CHANGELOG/\$VERSION.md"
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
cat >"$work/release-shape.py" <<'RELEASE_SHAPE_PY'
"""Structural checks on a release caller, on a bare python3.

Only two properties live here, both of which a line-oriented grep gets wrong in
ways that report green:

  * the trigger set must be EXACTLY {workflow_dispatch}. A blocklist accepts
    every trigger nobody listed, and an anchor on a bare `on:` line never sees
    the flow spelling `on: {workflow_dispatch: {...}, push: {...}}`.
  * a GITHUB_TOKEN bound to NODE_AUTH_TOKEN is legitimate only inside the step
    that runs `npm publish`. Checking the install step alone misses the same
    credential inherited from a job-level or workflow-level `env:`.

Anything this parser cannot read confidently is an error, never a pass.
"""
import re
import sys

path = sys.argv[1]
problems = []

with open(path, encoding="utf-8") as handle:
    raw_lines = handle.read().splitlines()


def strip_comment(line):
    """Drop a trailing comment without touching a `#` inside a quoted scalar."""
    out = []
    quote = None
    for index, char in enumerate(line):
        if quote:
            out.append(char)
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
            out.append(char)
            continue
        if char == "#" and (index == 0 or line[index - 1] in " \t"):
            break
        out.append(char)
    return "".join(out).rstrip()


lines = [strip_comment(line) for line in raw_lines]


def split_top_level(text):
    """Split a flow collection body on commas that are not nested or quoted."""
    parts = []
    current = []
    depth = 0
    quote = None
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            continue
        if char in "[{":
            depth += 1
        elif char in "]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(char)
    if "".join(current).strip():
        parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def keys_of_flow(text):
    text = text.strip()
    if text.startswith("{") and text.endswith("}"):
        return [
            part.split(":", 1)[0].strip().strip("'\"")
            for part in split_top_level(text[1:-1])
        ]
    if text.startswith("[") and text.endswith("]"):
        return [part.strip().strip("'\"") for part in split_top_level(text[1:-1])]
    return [text.strip("'\"")]


TRIGGER_KEY = re.compile(r"""^(?:on|'on'|"on"|true|True)\s*:(.*)$""")


def trigger_names():
    for index, line in enumerate(lines):
        match = TRIGGER_KEY.match(line)
        if not match:
            continue
        inline = match.group(1).strip()
        if inline:
            return keys_of_flow(inline)
        block = []
        for following in lines[index + 1:]:
            if not following.strip():
                continue
            if not following[:1].isspace():
                break
            block.append(following)
        if not block:
            return None
        indent = min(len(line) - len(line.lstrip()) for line in block)
        names = []
        for entry in block:
            if len(entry) - len(entry.lstrip()) != indent:
                continue
            text = entry.strip()
            if text.startswith("- "):
                text = text[2:].strip()
            elif text == "-":
                continue
            name = text.split(":", 1)[0].strip().strip("'\"")
            if name:
                names.append(name)
        return names or None
    return None


triggers = trigger_names()
if triggers is None:
    problems.append(
        "declares no readable top-level `on:` trigger. A release states the "
        "version it cuts, so it must be a workflow_dispatch and nothing else "
        "(ADR 0038, ADR 0060)"
    )
elif set(triggers) != {"workflow_dispatch"}:
    problems.append(
        "is triggered by %s. A release is dispatched with the version it cuts, "
        "never derived from repository activity, and never exposed as a "
        "reusable workflow another caller can fire (ADR 0038, ADR 0060)"
        % ", ".join(sorted(set(triggers)) or ["nothing"])
    )

GITHUB_TOKEN = re.compile(
    r"\$\{\{\s*(secrets\.GITHUB_TOKEN|github\.token)\s*\}\}", re.IGNORECASE
)
LIST_ITEM = re.compile(r"^(\s*)-\s")


def enclosing_step(index):
    """The list-item block containing `index`, or None if it is not in one."""
    cursor = index
    while cursor >= 0:
        match = LIST_ITEM.match(lines[cursor])
        if match:
            indent = len(match.group(1))
            end = cursor + 1
            while end < len(lines):
                current = lines[end]
                if current.strip() and len(current) - len(current.lstrip()) <= indent:
                    break
                end += 1
            if cursor <= index < end:
                return lines[cursor:end]
            return None
        cursor -= 1
    return None


for index, line in enumerate(lines):
    if "NODE_AUTH_TOKEN" not in line or not GITHUB_TOKEN.search(line):
        continue
    step = enclosing_step(index)
    if step is None or not any("npm publish" in entry for entry in step):
        problems.append(
            "binds NODE_AUTH_TOKEN to GITHUB_TOKEN at line %d, outside the "
            "`npm publish` step. A repository-scoped GITHUB_TOKEN cannot read a "
            "private @verjson package owned by another repository, so the "
            "install 401s after the tag has already been pushed. Install with "
            "NODE_AUTH_TOKEN and keep GITHUB_TOKEN for npm publish (#465)"
            % (index + 1)
        )

for problem in problems:
    sys.stderr.write("FAIL - %s %s\n" % (path, problem))
sys.exit(1 if problems else 0)
RELEASE_SHAPE_PY

# Every workflow that calls changelog-release.yml is a release caller, whatever
# it happens to be named. Keying these checks on one filename let a caller named
# anything else — publish.yml, release-package.yml, a second caller kept beside
# the first — collect zero checks and report green, which is the failure mode
# this whole file exists to remove.
release_workflows=""
for candidate in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
  [ -f "$candidate" ] || continue
  if grep -q 'changelog-release\.yml@' "$candidate"; then
    release_workflows="$release_workflows$candidate
"
  fi
done

while IFS= read -r release_workflow; do
  [ -n "$release_workflow" ] || continue
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

  # The release caller was the last adopter file still hand-copied from a
  # sibling, so one ordering bug propagated to every migrated repository at once
  # (#463, #464, #465). Provenance is asserted first because it is the only check
  # that also catches the defects nobody has named yet.
  grep -q "gen-changelog-caller.sh release-node $CONTRACT_REF" "$release_workflow" \
    || fail "$release_workflow is not the generated release caller at $CONTRACT_REF. Regenerate it: scripts/gen-changelog-caller.sh release-node $CONTRACT_REF > .github/workflows/release.yml"

  # Comments stripped before structural matching, for the reason the push_token
  # guard already states: the documented `# NOT GITHUB_TOKEN` note must not read
  # as the wiring it warns about.
  sed 's/#.*//' "$release_workflow" >"$work/release-stripped.yml"

  # The job that calls changelog-release.yml, isolated as a block rather than
  # grepped for. `needs:` and `runner:` are ordinary keys that also appear under
  # other jobs, so a guard matching them anywhere in the file passes on exactly
  # the shape it exists to reject.
  snapshot_job="$(awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    !in_jobs { next }
    /^[^[:space:]]/ { in_jobs = 0; next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (block ~ /changelog-release\.yml@/) { printf "%s", block; done = 1; exit }
      block = ""
    }
    { block = block $0 "\n" }
    END { if (!done && block ~ /changelog-release\.yml@/) printf "%s", block }
  ' "$work/release-stripped.yml")"

  # #463/#464. changelog-release.yml consumes NEXT/, writes an immutable
  # CHANGELOG/<version>.md, commits, tags and pushes to the default branch in one
  # atomic push. Nothing after that is recoverable by re-dispatch: the same
  # version is refused because the tag exists, a higher one because NEXT/ was
  # already consumed. So the snapshot may never be the first job to run.
  printf '%s\n' "$snapshot_job" | grep -qE '^[[:space:]]+needs:[[:space:]]*[^[:space:]]' \
    || fail "$release_workflow runs the irreversible snapshot with no needs:, so a red tree is discovered only after the tag has been pushed (#463, #464)"

  # #465. Omitting the optional runner input lets changelog-release.yml route the
  # snapshot by its own default while the caller's jobs route by another. On a
  # private repository the snapshot half — the half that mutates protected main —
  # then queues on hosted runners with no check run and no error.
  printf '%s\n' "$snapshot_job" | grep -qE '^[[:space:]]+runner:[[:space:]]*[^[:space:]]' \
    || fail "$release_workflow passes no explicit runner:, so the snapshot and the publish half can land on different runner pools (#465)"

  # The trigger surface and the install credential are checked structurally,
  # because both were shipped here as line-oriented greps first and both were
  # trivially evadable: an `on:` blocklist accepts every trigger nobody thought
  # to list (`workflow_call`, `release`, `workflow_run`), and a `^on:$` anchor
  # never sees `on: {workflow_dispatch: ..., push: ...}` written in flow style.
  # The rules below are allowlists over a parsed trigger set, and the parser
  # refuses anything it cannot read rather than passing it.
  #
  # PyYAML is deliberately not used: the canonical contract runs on a bare
  # python3 with no third-party dependency, and a "use it if importable"
  # fallback would put every adopter without it on the untested path.
  python3 "$work/release-shape.py" "$release_workflow" \
    || fail "$release_workflow: see above"
done <<RELEASE_WORKFLOWS
$release_workflows
RELEASE_WORKFLOWS
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
# The tolerated cause is decided from the TREE, not from the exit status (#399,
# duplicate #419). Keyed on the status alone, every renderer failure reported
# `ok - no unreleased fragments to render`: an unreachable contract fetch, a
# digest mismatch, a malformed fragment, a missing python3, the #398 argv
# ceiling. Each of those is a broken adopter announcing a clean release, and
# `2>/dev/null` threw away the only sentence that said which.
#
# So: an emptied NEXT/ is the one state that excuses a non-zero exit, and it is
# observable directly. A failure with fragments still present is a failure, and
# the captured stderr is printed rather than discarded.
#
# The rendered log travels through a file, never through a variable handed to
# execve. A single argv or environment string is capped at MAX_ARG_STRLEN — a
# fixed 128 KiB, unrelated to the far larger ARG_MAX that a check would read —
# so an adopter whose unreleased NEXT/ crossed that line died here with a bare
# "Argument list too long" and exit 126, naming neither the changelog nor the
# fragment count (#398). NEXT/ is per-change and never batched, so it grows past
# 128 KiB in the ordinary course of a busy release cycle; releasing consumes it,
# but the release path runs this suite, so the failure gated its own remedy.
render_rc=0
"$renderer" >"$work/rendered" 2>"$work/render-err" || render_rc=$?
# README.md and 0000-archive.md are excluded by name here for the same reason the
# python block skips them: neither is a renderable fragment, so a NEXT/ holding
# only those is "emptied" as far as the renderer is concerned.
renderable_left=$(find "$root/NEXT" -maxdepth 1 -type f -name '*.md' \
  ! -name 'README.md' ! -name '0000-archive.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$render_rc" -ne 0 ] && [ "${renderable_left:-0}" -gt 0 ]; then
  echo "the renderer exited $render_rc with $renderable_left unreleased fragment(s) still in NEXT/." >&2
  echo "This is not the post-release empty-NEXT/ case; the renderer itself is broken." >&2
  echo "--- renderer stderr ---" >&2
  cat "$work/render-err" >&2 || true
  echo "--- end renderer stderr ---" >&2
  fail "render-next failed for a reason other than an emptied NEXT/"
fi
if [ "$render_rc" -eq 0 ]; then
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
    #
    # The trailing group is the `; refs #a, #b` an entry renders when it links
    # issues it does not own (#316). Anchoring `_$` straight after the back-link
    # rejected that combination even though validation accepts it and the engine
    # renders it — and the test is generated, so the adopter had no legal way out
    # (#461). It stays a spelled-out shape rather than `.*`, because the anchor is
    # what makes a truncated or embellished back-link fail — and the group is
    # required, not optional, once the fragment declares `refs`, so a linkage the
    # render drops is caught by the same assertion that the missing back-link is.
    # Whether the numbers are the declared ones is the engine's business; this
    # file checks the shape it emits, never re-derives the input.
    if "issue" in meta:
        refs_group = r"(?:; refs #\d+(?:, #\d+)*)"
        if not meta.get("refs", "").strip():
            refs_group += "?"
        pattern = (
            rf"^_Date: {re.escape(meta['date'])}; issue #{re.escape(meta['issue'])}"
            rf"{refs_group}_$"
        )
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
  release-node)
    out="$(emit_release_node)"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
      printf '%s\n' "$out" | python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' 2>/dev/null \
        || { echo "internal error: generated release caller is not valid YAML; refusing to emit" >&2; exit 3; }
    fi
    # The verify job's guards are shell, and a release caller that cannot parse
    # fails at the step that was supposed to protect the release.
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
      printf '%s\n' "$out" | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
for job in doc["jobs"].values():
    for step in job.get("steps", []):
        if "run" in step:
            print(step["run"])
            print("")
' 2>/dev/null | bash -n 2>/dev/null \
        || { echo "internal error: generated release caller contains invalid bash; refusing to emit" >&2; exit 3; }
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
