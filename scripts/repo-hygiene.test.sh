#!/usr/bin/env bash
# Unit tests for scripts/repo-hygiene.sh (Verjson/.github#232, ADR 0046).
#
# Every fixture is a real git repository, and every assertion runs the script
# against a committed tree — the same surface CI checks. Nothing here inspects a
# diff: the policy is about the tree a merge would produce, so a README that a
# PR deletes has to read as absent, not as an unchanged file.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/scripts/repo-hygiene.sh"
tmp="$(mktemp -d)"
# A second, disposable repository outside $tmp. The sandbox guard below is
# tested by aiming a fixture git call at a repository it must refuse, and the
# assertion is that the repository is unchanged — so it must never be the
# checkout the suite is running from.
outside="$(mktemp -d)"
trap 'rm -rf "$tmp" "$outside"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$script" ] || { echo "FAIL - script not found: $script"; exit 1; }

# A README that satisfies the documented substance rule: three required topics,
# each with a real answer under it. Reused as the "compliant" baseline so a
# fixture only has to state how it deviates.
compliant_readme() {
  cat <<'MD'
# widget-service

## Purpose

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
}

# fixture_git <dir> [git args...] — git inside a fixture, pinned to the fixture.
# Every fixture git call goes through here. A fixture path that is not under
# $tmp is a bug in this file, but `git -C` does not treat it as one: it walks up
# to whatever repository encloses the path, so `add -A` + `commit` landed the
# runner's in-progress work in a stray host commit (#340). Refusing the call
# turns that into a failed test instead of a mutated checkout.
#
# git's own stdout is discarded here too. `git commit` with nothing staged
# reports "nothing to commit" on STDOUT, and that report is what a caller's
# command substitution captured ahead of the fixture path.
#
# Containment is checked on the RESOLVED path, because it is a property of the
# path and not of the string that spells it. A `"$tmp"/?*` prefix match is
# satisfied by `$tmp/../<anything>` and by a symlink under $tmp pointing
# anywhere, and both then satisfy `[ -d "$dir/.git" ]` as well — so the string
# test admitted exactly the host repository this helper exists to refuse.
fixture_git() {
  local dir="$1"; shift
  local real tmp_real
  real="$(cd "$dir" 2>/dev/null && pwd -P)" \
    || { printf 'FAIL - fixture dir does not exist: %q\n' "$dir"; exit 1; }
  tmp_real="$(cd "$tmp" && pwd -P)"
  case "$real" in
    "$tmp_real"/?*) ;;
    *) printf 'FAIL - fixture git outside the sandbox: %q\n' "$dir"; exit 1 ;;
  esac
  [ -d "$dir/.git" ] || { printf 'FAIL - not a fixture repository: %q\n' "$dir"; exit 1; }
  git -C "$dir" "$@" >/dev/null 2>&1 && return 0
  printf 'FAIL - fixture git failed in %q: git %s\n' "$dir" "$*"
  exit 1
}

# fixture <name> [--no-readme] — a committed git repo whose README.md is exactly
# what arrives on stdin. Stdin is streamed rather than captured: `$(cat)` strips
# trailing newlines, which would silently turn a whitespace-only fixture into a
# no-README fixture and leave the empty-README case testing nothing.
#
# The path comes back in $fixture_dir, never on stdout: printing it made every
# caller a `$(...)` capture of whatever the helper's own commands happened to
# print, and one no-op `git commit` was enough to prepend its report to the path
# (#340, #393). A variable cannot be polluted that way.
fixture_dir=''
fixture() {
  local name="$1"
  # `git init -q "$dir"` below is raw — it runs before any call is screened by
  # fixture_git — so the name has to be a name. A path-shaped one would stand a
  # repository up outside the sandbox and only then start being guarded.
  case "$name" in
    ''|*/*|.|..|.*) printf 'FAIL - fixture name must be a plain name: %q\n' "$name"; exit 1 ;;
  esac
  local dir="$tmp/$name"
  local readme=1
  [ "${2:-}" = --no-readme ] && readme=0
  # A reused name re-enters a fixture that is already built and committed, so
  # the second build stages nothing and the commit becomes the no-op above. It
  # is never what a caller meant, and it is how the docs/ case ended up
  # asserting against a junk path instead of a fixture (#393).
  [ -e "$dir" ] && { printf 'FAIL - fixture name reused: %s\n' "$name"; exit 1; }
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  [ -d "$dir/.git" ] || { printf 'FAIL - could not init fixture: %s\n' "$name"; exit 1; }
  fixture_git "$dir" config user.name test
  fixture_git "$dir" config user.email test@example.com
  printf 'placeholder\n' >"$dir/.keep"
  if [ "$readme" -eq 1 ]; then cat >"$dir/README.md"; else cat >/dev/null; fi
  fixture_git "$dir" add -A
  fixture_git "$dir" commit -qm fixture
  fixture_dir="$dir"
}

# check <root> [extra args...] — run the script in enforce mode over a fixture.
# Enforce is the mode under test for policy verdicts; audit-mode reporting gets
# its own cases below.
check() {
  local root="$1"; shift
  REPO_HYGIENE_ROOT="$root" bash "$script" --mode enforce "$@"
}

# --------------------------------------------------------------------------
# The tree has no root README at all.
# --------------------------------------------------------------------------
fixture missing --no-readme </dev/null; missing="$fixture_dir"
check "$missing" >"$tmp/missing.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -qi 'readme' "$tmp/missing.out"; } \
  && pass "a tree with no root README is a finding" \
  || { fail "missing README accepted or unreported (rc=$rc)"; sed 's/^/diag - /' "$tmp/missing.out"; }

# --------------------------------------------------------------------------
# The README exists but says nothing.
# --------------------------------------------------------------------------
fixture empty <<'MD'


MD
empty="$fixture_dir"
check "$empty" >"$tmp/empty.out" 2>&1
rc=$?
# Pinned to the emptiness verdict, not just to a non-zero exit: an empty README
# also has no sections, so a bare `rc != 0` would still pass with the emptiness
# rule deleted, and the case would be documenting nothing.
{ [ "$rc" -eq 1 ] && grep -qi 'non-empty' "$tmp/empty.out"; } \
  && pass "a whitespace-only README is a finding, reported as emptiness" \
  || { fail "empty README accepted or misreported (rc=$rc)"; sed 's/^/diag - /' "$tmp/empty.out"; }

# --------------------------------------------------------------------------
# Substance. A README that is present and non-empty but answers none of the
# three required questions is the case that prompted #232 — a title and a
# placeholder are what an unseeded repository already has.
# --------------------------------------------------------------------------
fixture placeholder <<'MD'
# widget-service

TODO
MD
placeholder="$fixture_dir"
check "$placeholder" >"$tmp/placeholder.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a title-and-placeholder README is a finding" \
  || { fail "placeholder README accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/placeholder.out"; }

# --------------------------------------------------------------------------
# The rule has to be satisfiable, or it is not a policy but an outage.
# --------------------------------------------------------------------------
# Process substitution, not a pipe: a pipeline would run `fixture` in a subshell
# where the path it publishes cannot reach the caller.
fixture valid < <(compliant_readme); valid="$fixture_dir"
check "$valid" >"$tmp/valid.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a README answering all three questions is accepted" \
  || { fail "compliant README rejected (rc=$rc)"; sed 's/^/diag - /' "$tmp/valid.out"; }

# --------------------------------------------------------------------------
# Headings alone are copy-paste. Each required topic needs a real answer under
# it, or the seeded template passes while saying nothing.
# --------------------------------------------------------------------------
fixture stubbed <<'MD'
# widget-service

## Purpose

TODO

## Ownership

TBD

## Local validation

N/A
MD
stubbed="$fixture_dir"
check "$stubbed" >"$tmp/stubbed.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "required headings with placeholder bodies are a finding" \
  || { fail "stubbed sections accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/stubbed.out"; }

# --------------------------------------------------------------------------
# Deletion PR. The compliant README is on the base commit and removed on the
# head commit — there is no added line to inspect, and a diff-based check reads
# the PR as touching nothing relevant. The resulting tree has no README.
# --------------------------------------------------------------------------
fixture deleted < <(compliant_readme); deleted="$fixture_dir"
fixture_git "$deleted" rm -q README.md
fixture_git "$deleted" commit -qm 'chore: drop the README'
check "$deleted" >"$tmp/deleted.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a PR that deletes the README is a finding" \
  || { fail "deletion of the README accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/deleted.out"; }

# The same tree at its parent still passes, which is what proves the case above
# came from the deletion rather than from a fixture that was never compliant.
check "$deleted" --ref HEAD~1 >"$tmp/deleted-base.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "the base commit of the deletion PR is still compliant" \
  || { fail "deletion fixture was never compliant (rc=$rc)"; sed 's/^/diag - /' "$tmp/deleted-base.out"; }

# --------------------------------------------------------------------------
# Fail closed on a broken lookup. A tree the script cannot read is a FAULT, not
# a verdict — and a fault must be loud in BOTH modes. Audit mode exists to keep
# a policy finding from breaking a consumer on day one; it is not a licence to
# report success when the check never ran. A hygiene check that passes when it
# cannot read the tree is one that silently stops working.
# --------------------------------------------------------------------------
notrepo="$tmp/not-a-repo"
mkdir -p "$notrepo"
compliant_readme >"$notrepo/README.md"
REPO_HYGIENE_ROOT="$notrepo" bash "$script" --mode audit >"$tmp/notrepo.out" 2>&1
rc=$?
{ [ "$rc" -eq 2 ] && grep -qi 'could not read' "$tmp/notrepo.out"; } \
  && pass "an unreadable tree fails closed as a fault, even in audit mode" \
  || { fail "unreadable tree reported success (rc=$rc)"; sed 's/^/diag - /' "$tmp/notrepo.out"; }

# --------------------------------------------------------------------------
# Audit is the default, so landing this check cannot break a consumer's CI on
# day one. It must still SAY what it found — an audit that reports nothing
# produces no remediation backlog, which is the whole point of the phase.
# --------------------------------------------------------------------------
REPO_HYGIENE_ROOT="$placeholder" bash "$script" >"$tmp/audit.out" 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && grep -qi 'audit' "$tmp/audit.out" && grep -qi 'purpose' "$tmp/audit.out"; } \
  && pass "the default mode audits: findings are reported, exit stays 0" \
  || { fail "default mode is not a reporting audit (rc=$rc)"; sed 's/^/diag - /' "$tmp/audit.out"; }

REPO_HYGIENE_ROOT="$placeholder" bash "$script" --mode nonsense >"$tmp/badmode.out" 2>&1
rc=$?
[ "$rc" -eq 2 ] \
  && pass "an unrecognised mode is rejected instead of silently auditing" \
  || { fail "unknown mode fell through to a pass (rc=$rc)"; sed 's/^/diag - /' "$tmp/badmode.out"; }

# --------------------------------------------------------------------------
# Exemptions. The register is a tracked file in THIS repository, so granting one
# is a reviewed PR here — never a claim made by the repository being checked.
# Each row: repository, class, review-by date, reason.
# --------------------------------------------------------------------------
register="$tmp/exemptions.tsv"
{
  printf '# repository\tclass\treview-by\treason\n'
  printf 'Verjson/old-thing\tarchived\t2027-01-01\tArchived 2026-05; read-only history.\n'
  printf 'Verjson/upstream-mirror\tmirror\t2027-01-01\tVendor snapshot; upstream owns the README.\n'
  printf 'Verjson/verjson-schema-dist\tgenerated\t2027-01-01\tPublished artefacts only; generator repo documents it.\n'
  printf 'Verjson/new-service\tbootstrap\t2026-09-01\tReserved name; seeded in the next sprint.\n'
} >"$register"

# exempt_check <repository> <root> — audit-mode default, so an exemption that
# only works under enforce would still show up as a day-one finding.
exempt_check() {
  REPO_HYGIENE_ROOT="$2" REPO_HYGIENE_EXEMPTIONS="$register" REPO_HYGIENE_TODAY=2026-08-02 \
    bash "$script" --mode enforce --repository "$1"
}

while IFS=' ' read -r repository class; do
  exempt_check "$repository" "$missing" >"$tmp/exempt-$class.out" 2>&1
  rc=$?
  { [ "$rc" -eq 0 ] && grep -qi "exempt" "$tmp/exempt-$class.out"; } \
    && pass "a registered $class repository is exempt and says so" \
    || { fail "$class exemption not honoured (rc=$rc)"; sed 's/^/diag - /' "$tmp/exempt-$class.out"; }
done <<'CASES'
Verjson/old-thing archived
Verjson/upstream-mirror mirror
Verjson/verjson-schema-dist generated
Verjson/new-service bootstrap
CASES

# An unregistered repository is not exempt, however plausible its name.
exempt_check Verjson/old-thing-2 "$missing" >"$tmp/unregistered.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a repository absent from the register is not exempt" \
  || { fail "unregistered repository treated as exempt (rc=$rc)"; sed 's/^/diag - /' "$tmp/unregistered.out"; }

# The self-assertion hole: a repository that ships its own exemption marker is
# claiming a grant nobody reviewed. Only the central register can exempt.
fixture selfclaim --no-readme </dev/null; selfclaim="$fixture_dir"
{
  printf 'exempt: true\nclass: archived\nreason: we say so\n' >"$selfclaim/.repo-hygiene-exempt"
  printf 'Verjson/selfclaim\tarchived\t2027-01-01\twe say so\n' >"$selfclaim/exemptions.tsv"
} 2>/dev/null
fixture_git "$selfclaim" add -A
fixture_git "$selfclaim" commit -qm 'claim an exemption'
exempt_check Verjson/selfclaim "$selfclaim" >"$tmp/selfclaim.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a repository cannot exempt itself with an in-tree marker" \
  || { fail "self-asserted exemption honoured — that is a bypass (rc=$rc)"; sed 's/^/diag - /' "$tmp/selfclaim.out"; }

# A lapsed row stops exempting, so the backlog re-surfaces instead of being
# permanently forgotten under a grant nobody re-read.
REPO_HYGIENE_ROOT="$missing" REPO_HYGIENE_EXEMPTIONS="$register" REPO_HYGIENE_TODAY=2026-09-02 \
  bash "$script" --mode enforce --repository Verjson/new-service >"$tmp/lapsed.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -qi 'laps' "$tmp/lapsed.out"; } \
  && pass "an exemption past its review-by date stops exempting" \
  || { fail "lapsed exemption still honoured (rc=$rc)"; sed 's/^/diag - /' "$tmp/lapsed.out"; }

# A register the script cannot make sense of is a fault. Reading it as "nobody is
# exempt" would be quietly wrong for the exempt repos; reading it as "skip the
# register" would be quietly wrong for everyone else.
malformed="$tmp/malformed.tsv"
printf 'Verjson/old-thing\tdeprecated\t2027-01-01\tclass nobody agreed to\n' >"$malformed"
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$malformed" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --mode audit --repository Verjson/anything >"$tmp/malformed.out" 2>&1
rc=$?
{ [ "$rc" -eq 2 ] && grep -qi 'deprecated' "$tmp/malformed.out"; } \
  && pass "an unrecognised exemption class is a fault, not a narrower exemption" \
  || { fail "unknown exemption class passed silently (rc=$rc)"; sed 's/^/diag - /' "$tmp/malformed.out"; }

incomplete="$tmp/incomplete.tsv"
printf 'Verjson/old-thing\tarchived\t\t\n' >"$incomplete"
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$incomplete" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --mode audit --repository Verjson/old-thing >"$tmp/incomplete.out" 2>&1
rc=$?
[ "$rc" -eq 2 ] \
  && pass "an exemption without a reason and a review-by date is rejected" \
  || { fail "undocumented exemption accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/incomplete.out"; }

# A register path that does not resolve means the central checkout is missing or
# renamed. Silently exempting nobody would look like a working check.
REPO_HYGIENE_ROOT="$valid" REPO_HYGIENE_EXEMPTIONS="$tmp/no-such-register.tsv" \
  bash "$script" --mode audit --repository Verjson/old-thing >"$tmp/noregister.out" 2>&1
rc=$?
{ [ "$rc" -eq 2 ] && grep -qi 'register' "$tmp/noregister.out"; } \
  && pass "a missing exemption register is a fault, not an empty one" \
  || { fail "missing register treated as no exemptions (rc=$rc)"; sed 's/^/diag - /' "$tmp/noregister.out"; }

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# A register whose final row carries no trailing newline still grants its
# exemption. `while read` returns non-zero on an unterminated last line, so
# without the `|| [ -n "$reg_repo" ]` guard that row is silently skipped: the
# repository is checked instead of exempted, and nothing says the grant was
# dropped. Fail-closed, but silently — the next person to append a row with an
# editor that omits the final newline loses the exemption with no diagnostic.
# --------------------------------------------------------------------------
register_no_eol="$tmp/exemptions-no-eol.tsv"
{
  printf '# repository\tclass\treview-by\treason\n'
  printf 'Verjson/last-row\tarchived\t2027-01-01\tArchived; this row has no trailing newline.'
} >"$register_no_eol"
REPO_HYGIENE_ROOT="$missing" REPO_HYGIENE_EXEMPTIONS="$register_no_eol" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --mode enforce --repository Verjson/last-row >"$tmp/no-eol.out" 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && grep -qi "exempt" "$tmp/no-eol.out"; } \
  && pass "a final register row without a trailing newline still exempts" \
  || { fail "an unterminated final register row was silently dropped (rc=$rc)"; sed 's/^/diag - /' "$tmp/no-eol.out"; }

# --------------------------------------------------------------------------
# Markdown block context. The parser is line-oriented, so without explicit
# fence/comment tracking a README whose whole body is commented out — or whose
# "headings" are shell comments in an example — renders as nothing and still
# answers all three questions. Both are full policy bypasses, not nits.
# --------------------------------------------------------------------------
fixture commented <<'MD'
<!--
# Purpose
Serves the widget catalogue to the storefront and keeps its search index warm.
# Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.
# Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
-->
MD
commented="$fixture_dir"
out="$(check "$commented" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no purpose section' <<<"$out" \
  && pass "headings inside an HTML comment answer nothing" \
  || fail "a fully commented-out README passed (rc=$rc): $out"

fixture fenced <<'MD'
# widget-service

```sh
# Purpose
# Ownership
# Local validation
```
MD
fenced="$fixture_dir"
out="$(check "$fenced" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no purpose section' <<<"$out" \
  && pass "headings inside a fenced code block answer nothing" \
  || fail "a README whose only headings are inside a fence passed (rc=$rc): $out"

# CommonMark closes a fence only with a run of the SAME character at least as
# long as the opening one, so the ``` line below is code, not a close — and
# everything after it is still inside the outer fence. A parser that toggles on
# any fence line reads the rest as rendered sections and reports a README that
# answers nothing as compliant (#352).
fixture fence-nested <<'MD'
# widget-service

````
```
# Purpose
Serves the widget catalogue to the storefront and keeps its search index warm.
# Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.
# Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
````
MD
fence_nested="$fixture_dir"
out="$(check "$fence_nested" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no purpose section' <<<"$out" \
  && pass "a shorter inner fence does not end the block that encloses it" \
  || fail "headings inside an unclosed four-backtick fence counted (rc=$rc): $out"

# The other half of the same rule: a tilde run does not close a backtick block.
fixture fence-mismatched <<'MD'
# widget-service

```
~~~
# Purpose
Serves the widget catalogue to the storefront and keeps its search index warm.
# Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.
# Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
```
MD
fence_mismatched="$fixture_dir"
out="$(check "$fence_mismatched" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no purpose section' <<<"$out" \
  && pass "a fence of the other character does not close the open block" \
  || fail "a tilde run closed a backtick fence (rc=$rc): $out"

# And the rule has to let go: a run at least as long as the opener closes it, or
# every README with an example block would read as one unending code block and
# the check would report findings nobody can clear. Longer, indented, and tilde
# closures are all real CommonMark closes.
fixture fence-closed <<'MD'
# widget-service

  ~~~sh
  echo 'an indented example'
  ~~~~

```text
# not a heading
````

## Purpose

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
fence_closed="$fixture_dir"
out="$(check "$fence_closed" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a longer or equal run of the opening character closes the fence" \
  || fail "sections after a legitimately closed fence were not seen (rc=$rc): $out"

# A run that carries an info string opens a block; it never closes one. Without
# that, the ```sh line below would close the block and re-expose the bypass.
fixture fence-info-string <<'MD'
# widget-service

```
```sh
# Purpose
Serves the widget catalogue to the storefront and keeps its search index warm.
# Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.
# Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
```
MD
fence_info="$fixture_dir"
out="$(check "$fence_info" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no purpose section' <<<"$out" \
  && pass "a fence line with an info string cannot close a block" \
  || fail "an info-string fence line closed the open block (rc=$rc): $out"

# The two block contexts are not independent, so the order they are tracked in
# is the behaviour. Inside a fence, `<!--` is a code sample: an example of HTML
# comment syntax opened a comment that ran to end of file and blanked the whole
# parse, reporting a compliant README as answering nothing.
fixture fence-holds-comment <<'MD'
# widget-service

```html
<!-- example
```

## Purpose

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
fence_holds_comment="$fixture_dir"
out="$(check "$fence_holds_comment" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "an unterminated <!-- inside a fence is a code sample, not a comment" \
  || fail "a fenced <!-- swallowed the rest of the README (rc=$rc): $out"

# And the same order in the other direction. A commented-out fence renders as
# nothing, so it opens nothing: hoisting fence tracking above the open-comment
# branch would leave this lone ``` holding a block open to end of file and hide
# all three real sections behind it.
fixture comment-holds-fence <<'MD'
# widget-service

<!--
```sh
# not a heading
-->

## Purpose

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
comment_holds_fence="$fixture_dir"
out="$(check "$comment_holds_fence" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a fence line inside an HTML comment opens no block" \
  || fail "a commented-out fence swallowed the rest of the README (rc=$rc): $out"

# A subheading is part of its parent's answer, not the end of it. Resetting on
# any heading made every sub-sectioned README a false finding, which would have
# dominated the rollout backlog.
fixture nested <<'MD'
# widget-service

## Purpose

### Goals

Serves the widget catalogue to the storefront and keeps its search index warm.

## Ownership

Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation

Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
nested="$fixture_dir"
out="$(check "$nested" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a subheading continues its parent section rather than ending it" \
  || fail "a sub-sectioned README was reported non-compliant (rc=$rc): $out"

# A CRLF checkout must read the same as an LF one: the trailing \r otherwise
# defeats the ([ \t]|:|$) alias anchor and fails every topic at once.
fixture crlf < <(compliant_readme | sed 's/$/\r/'); crlf_dir="$fixture_dir"
out="$(check "$crlf_dir" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a CRLF README reads the same as an LF one" \
  || fail "a compliant CRLF README was reported non-compliant (rc=$rc): $out"

# --------------------------------------------------------------------------
# Argument handling. `shift 2` with one argument left fails without shifting,
# so a trailing flag used to spin forever instead of reporting anything.
# --------------------------------------------------------------------------
out="$(timeout 10 bash "$script" --repo-root "$valid" --mode 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "a flag with no value is a fault, not an infinite loop" \
  || fail "a trailing --mode did not fault cleanly (rc=$rc; 124 = hung): $out"

# --------------------------------------------------------------------------
# review-by is shape-checked, not merely present. The lapse test is a
# lexicographic compare, so an unparseable date would grant a permanent
# exemption and silently void the invariant the register exists to keep.
# --------------------------------------------------------------------------
for bad_date in never 9999-99-99 2027-1-1; do
  reg_bad="$tmp/register-bad-date.tsv"
  printf 'Verjson/bad-date\tarchived\t%s\tunparseable review-by\n' "$bad_date" >"$reg_bad"
  out="$(REPO_HYGIENE_EXEMPTIONS="$reg_bad" REPO_HYGIENE_TODAY=2026-08-02 \
    bash "$script" --repo-root "$missing" --mode enforce --repository Verjson/bad-date 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] \
    && pass "review-by '$bad_date' is a fault, not a permanent exemption" \
    || fail "review-by '$bad_date' was accepted (rc=$rc): $out"
done

# An undeterminable date makes every lapse test false, so nothing would expire.
out="$(REPO_HYGIENE_TODAY=not-a-date REPO_HYGIENE_EXEMPTIONS="$register" \
  bash "$script" --repo-root "$missing" --mode enforce --repository Verjson/old-thing 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "an undeterminable today is a fault, so nothing silently never lapses" \
  || fail "an unparseable today did not fault (rc=$rc): $out"

# A lapsed row must not abort the scan: rows after it still need validating.
reg_after="$tmp/register-lapsed-then-malformed.tsv"
{
  printf 'Verjson/lapsed\tarchived\t2020-01-01\tlapsed long ago\n'
  printf 'Verjson/other\tnot-a-class\t2027-01-01\tmalformed row after the lapsed one\n'
} >"$reg_after"
out="$(REPO_HYGIENE_EXEMPTIONS="$reg_after" REPO_HYGIENE_TODAY=2026-08-02 \
  bash "$script" --repo-root "$missing" --mode enforce --repository Verjson/lapsed 2>&1)"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "a malformed row after a lapsed one is still a fault" \
  || fail "a lapsed row aborted validation of the rows after it (rc=$rc): $out"

# The shipped artefacts, not just the logic.
# --------------------------------------------------------------------------

# The register that actually ships must parse under the same fail-closed rules
# as the fixtures above — a malformed row committed here would fault every
# consumer at once.
REPO_HYGIENE_ROOT="$valid" bash "$script" --mode enforce --repository Verjson/not-registered \
  >"$tmp/register.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "the committed exemption register parses under the shipped rules" \
  || { fail "the committed register is malformed or missing (rc=$rc)"; sed 's/^/diag - /' "$tmp/register.out"; }

# Correct construction: the README a new repository is seeded with must satisfy
# the policy it is seeded to satisfy. A template that fails the check teaches
# every new repo to start non-compliant.
template="$repo_root/docs/repo-hygiene/README.template.md"
if [ -f "$template" ]; then
  fixture seeded <"$template"; seeded="$fixture_dir"
  check "$seeded" >"$tmp/template.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] \
    && pass "the seeded template README satisfies the policy it seeds" \
    || { fail "the template README does not pass the check (rc=$rc)"; sed 's/^/diag - /' "$tmp/template.out"; }
else
  fail "no seeded README template at docs/repo-hygiene/README.template.md"
fi

# This repository is a Verjson repository too, and it is the one that publishes
# the rule. Dogfooding it here is what keeps the rule honest about being usable.
check "$repo_root" >"$tmp/self.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "this repository's own README satisfies the rule it publishes" \
  || { fail "the publishing repository fails its own hygiene check (rc=$rc)"; sed 's/^/diag - /' "$tmp/self.out"; }

# --------------------------------------------------------------------------
# The harness's own invariants. A fixture bug here is not a failed assertion by
# default — it is `git add -A && git commit` landing on whatever repository
# encloses the path, which is how this suite once swept in-progress work into a
# stray commit on the branch it was run from (#340, #393). Both guards abort the
# suite, so both are exercised in a subshell.
# --------------------------------------------------------------------------
( fixture missing --no-readme </dev/null ) >"$tmp/reuse.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'fixture name reused' "$tmp/reuse.out"; } \
  && pass "a reused fixture name is refused instead of re-entering the fixture" \
  || { fail "a reused fixture name was accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/reuse.out"; }

# `git init -q "$tmp/$name"` is raw, so the name has to be a name. A path-shaped
# one puts a repository outside the sandbox before any git call is screened.
( fixture ../escaped-fixture </dev/null ) >"$tmp/badname.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'fixture name must be a plain name' "$tmp/badname.out"; } \
  && pass "a path-shaped fixture name is refused before anything is created" \
  || { fail "a path-shaped fixture name was accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/badname.out"; }
[ ! -e "$tmp/../escaped-fixture" ] \
  && pass "the refused fixture name left nothing outside the sandbox" \
  || { fail "a refused fixture name still created a directory outside the sandbox"; rm -rf "$tmp/../escaped-fixture"; }

# Raw git on purpose: this repository is the one fixture_git must refuse to
# touch, so building it through the helper would be circular.
git init -q "$outside"
git -C "$outside" config user.name test
git -C "$outside" config user.email test@example.com
git -C "$outside" commit -q --allow-empty -m 'outside the sandbox' >/dev/null 2>&1
outside_head="$(git -C "$outside" rev-parse --verify HEAD)"
( fixture_git "$outside" commit -q --allow-empty -m 'this must never run' ) >"$tmp/escape.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'outside the sandbox' "$tmp/escape.out"; } \
  && pass "a fixture git call outside the sandbox is refused" \
  || { fail "fixture git accepted a path outside \$tmp (rc=$rc)"; sed 's/^/diag - /' "$tmp/escape.out"; }
[ "$(git -C "$outside" rev-parse --verify HEAD)" = "$outside_head" ] \
  && pass "the refused call left the outside repository unchanged" \
  || fail "fixture git committed to a repository outside the sandbox"

# Containment is a property of the resolved path, not of the string. Both repos
# come from `mktemp -d`, so they are siblings under $TMPDIR and `$tmp/../<name>`
# names the outside repository while still matching a "$tmp"/?* prefix test.
[ "${tmp%/*}" = "${outside%/*}" ] \
  || fail "the sandbox and the outside repository are not siblings — the traversal case is not exercising the escape"
traversal="$tmp/../${outside##*/}"
( fixture_git "$traversal" commit -q --allow-empty -m 'this must never run' ) >"$tmp/traversal.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'outside the sandbox' "$tmp/traversal.out"; } \
  && pass "a fixture path that walks out of the sandbox with .. is refused" \
  || { fail "fixture git accepted a ..-traversal out of \$tmp (rc=$rc)"; sed 's/^/diag - /' "$tmp/traversal.out"; }
[ "$(git -C "$outside" rev-parse --verify HEAD)" = "$outside_head" ] \
  && pass "the refused ..-traversal left the outside repository unchanged" \
  || fail "fixture git committed through a ..-traversal to a repository outside the sandbox"

# A symlink lives inside the sandbox by every string measure and by `[ -d
# "$dir/.git" ]`, and still hands git a repository outside it.
ln -s "$outside" "$tmp/escape-link"
( fixture_git "$tmp/escape-link" commit -q --allow-empty -m 'this must never run' ) >"$tmp/symlink.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'outside the sandbox' "$tmp/symlink.out"; } \
  && pass "a symlink out of the sandbox is refused" \
  || { fail "fixture git followed a symlink out of \$tmp (rc=$rc)"; sed 's/^/diag - /' "$tmp/symlink.out"; }
[ "$(git -C "$outside" rev-parse --verify HEAD)" = "$outside_head" ] \
  && pass "the refused symlink left the outside repository unchanged" \
  || fail "fixture git committed through a symlink to a repository outside the sandbox"

# Resolving the path means a path that does not resolve has to be its own
# refusal, not an empty string that then falls through the containment test.
( fixture_git "$tmp/never-created" status ) >"$tmp/missing-dir.out" 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'fixture dir does not exist' "$tmp/missing-dir.out"; } \
  && pass "a fixture path that does not resolve is refused, not treated as the sandbox" \
  || { fail "an unresolvable fixture path was not refused (rc=$rc)"; sed 's/^/diag - /' "$tmp/missing-dir.out"; }

# --------------------------------------------------------------------------
# Edge cases.
# --------------------------------------------------------------------------

# Root means root. A repository with rich docs under docs/ and nothing at the
# top level is exactly the "where do I start?" case #232 is about.
# Its own fixture name: this case reused `nested` from the sub-heading case
# above, which is what turned its path into a junk string (#393).
fixture docs-only --no-readme </dev/null; docs_only="$fixture_dir"
mkdir -p "$docs_only/docs"
compliant_readme >"$docs_only/docs/README.md"
fixture_git "$docs_only" add -A
fixture_git "$docs_only" commit -qm 'document under docs/'
# The verdict below is only about docs/ if the thing checked IS the fixture. A
# polluted path landed the README in a junk directory and left the check reading
# an empty root — passing for the wrong reason (#393).
{ [ -f "$docs_only/docs/README.md" ] && ! [ -f "$docs_only/README.md" ]; } \
  && pass "the docs/ fixture really carries its README under docs/ and not at root" \
  || fail "the docs/ fixture was never built as documented"
check "$docs_only" >"$tmp/docs-only.out" 2>&1
rc=$?
# Pinned to the verdict, not just to rc=1: every other way this fixture can go
# wrong also exits 1, so a bare exit-code check would keep passing for the wrong
# reason — which is the #393 failure mode itself.
{ [ "$rc" -eq 1 ] && grep -q 'no root README' "$tmp/docs-only.out"; } \
  && pass "a README under docs/ does not satisfy the root requirement" \
  || { fail "nested README accepted as the root README (rc=$rc)"; sed 's/^/diag - /' "$tmp/docs-only.out"; }

# GitHub renders `readme.md` and `Readme.md` as the repository README, so the
# check must too — otherwise it reports a finding a reader cannot reproduce.
fixture lowercase < <(compliant_readme); lowercase="$fixture_dir"
fixture_git "$lowercase" mv README.md readme.md
fixture_git "$lowercase" commit -qm 'lowercase the filename'
check "$lowercase" >"$tmp/lowercase.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a lowercase readme.md is the README, as GitHub renders it" \
  || { fail "case variant of README.md reported as missing (rc=$rc)"; sed 's/^/diag - /' "$tmp/lowercase.out"; }

# Headings are prose. Casing, trailing colons and deeper levels are all the same
# answer, and rejecting them would make the rule about wording rather than about
# whether the question was answered.
fixture variants <<'MD'
# widget-service

### OVERVIEW:
Serves the widget catalogue to the storefront and keeps its search index warm.

#### Maintainers
Owned by the platform team; contact #verjson-platform or open an issue here.

## Getting started
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
variants="$fixture_dir"
check "$variants" >"$tmp/variants.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "heading case, depth and trailing punctuation do not change the answer" \
  || { fail "an equivalent heading spelling was rejected (rc=$rc)"; sed 's/^/diag - /' "$tmp/variants.out"; }

# Non-ASCII prose is prose. A byte-vs-character mix-up in the substance floor
# would quietly hold non-English READMEs to a shorter or longer bar than English.
fixture unicode <<'MD'
# gestión-de-widgets

## Propósito
Sirve el catálogo de widgets a la tienda y mantiene su índice de búsqueda.

## Ownership
Owned by the platform team; contact #verjson-platform or open an issue here.

## Local validation
Ejecuta `npm ci && npm test` antes de subir; `npm run dev` arranca en :3000.
MD
unicode="$fixture_dir"
check "$unicode" >"$tmp/unicode.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a heading outside the documented alias list is still a finding" \
  || { fail "an untranslated alias silently satisfied the purpose topic (rc=$rc)"; sed 's/^/diag - /' "$tmp/unicode.out"; }

fixture unicode-ok <<'MD'
# gestión-de-widgets

## Purpose
Sirve el catálogo de widgets a la tienda y mantiene su índice de búsqueda.

## Ownership
Equipo de plataforma; escríbenos en #verjson-platform o abre una incidencia.

## Local validation
Ejecuta `npm ci && npm test` antes de subir; `npm run dev` arranca en :3000.
MD
unicode_ok="$fixture_dir"
check "$unicode_ok" >"$tmp/unicode-ok.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] \
  && pass "non-ASCII prose counts toward the substance floor" \
  || { fail "unicode body measured against the wrong floor (rc=$rc)"; sed 's/^/diag - /' "$tmp/unicode-ok.out"; }

# A section whose only content is a heading of its own has no answer under it.
fixture runon <<'MD'
# widget-service

## Purpose
## Ownership
## Local validation
Run `npm ci && npm test` before pushing; `npm run dev` starts it on :3000.
MD
runon="$fixture_dir"
check "$runon" >"$tmp/runon.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] \
  && pass "a heading immediately followed by the next heading has no answer" \
  || { fail "empty section accepted (rc=$rc)"; sed 's/^/diag - /' "$tmp/runon.out"; }

# --------------------------------------------------------------------------
# Workflow contract. The script's guarantees only hold if the workflow runs the
# CENTRAL copy of it against the CONSUMER's tree — running the consumer's copy
# would hand the audited repository the check that audits it.
# --------------------------------------------------------------------------
wf="$repo_root/.github/workflows/repo-hygiene.yml"
if [ ! -f "$wf" ]; then
  fail "no reusable hygiene workflow at .github/workflows/repo-hygiene.yml"
else
  grep -qE '^  workflow_call:' "$wf" \
    && pass "the hygiene check ships as one reusable workflow, not a copied job" \
    || fail "repo-hygiene.yml is not callable as a reusable workflow"

  # Audit by default: landing this cannot turn any consumer's CI red on day one.
  # Enforcement is a per-caller opt-in and an org decision, not a side effect.
  mode_default="$(awk '/^      mode:/{f=1} f && /default:/{print; exit}' "$wf")"
  grep -qF "'audit'" <<<"$mode_default" \
    && pass "the mode input defaults to audit, so rollout cannot break consumers" \
    || fail "repo-hygiene.yml does not default to audit mode (got: ${mode_default:-none})"

  # Single quotes are deliberate throughout this block: these are literal
  # workflow fragments to match, not shell expansions. (shellcheck SC2016)
  # shellcheck disable=SC2016
  grep -qF 'repository: Verjson/.github' "$wf" \
    && grep -qF 'ref: ${{ inputs.hygiene_ref }}' "$wf" \
    && pass "the workflow checks out the central repository at a caller-pinned ref" \
    || fail "repo-hygiene.yml does not check out the central repository at a pinned ref"

  # An unmerged policy ref (a PR ref on this public repository) would let the
  # audited repository supply its own exemption row and its own script, so the
  # workflow must prove the ref is reachable from the default branch. A SHA
  # shape check is not the property — a PR-branch commit is a SHA too.
  grep -qF 'compare/main...$resolved' "$wf" \
    && grep -qE 'identical\|behind' "$wf" \
    && pass "the workflow refuses a policy ref not reachable from main" \
    || fail "repo-hygiene.yml does not verify hygiene_ref reachability from main"

  # The invocation must name the central checkout path. A bare
  # `scripts/repo-hygiene.sh` would resolve inside the consumer's tree.
  grep -qE 'bash \.repo-hygiene/scripts/repo-hygiene\.sh' "$wf" \
    && pass "the workflow runs the central script, not the consumer's copy of it" \
    || fail "repo-hygiene.yml does not run the script from the central checkout"

  # Through the environment rather than interpolated into the script body — the
  # house rule for every expansion that reaches a `run:` block.
  # shellcheck disable=SC2016
  { grep -qF 'HYGIENE_REPOSITORY: ${{ github.repository }}' "$wf" \
    && grep -qF -- '--repository "$HYGIENE_REPOSITORY"' "$wf"; } \
    && pass "the workflow identifies the audited repository for the register" \
    || fail "repo-hygiene.yml does not pass the audited repository through the environment"

  # shellcheck disable=SC2016
  grep -qF -- '--repo-root "$GITHUB_WORKSPACE"' "$wf" \
    && pass "the workflow audits the consumer's checked-out tree" \
    || fail "repo-hygiene.yml does not point the check at the consumer tree"
fi

# Wired, or it does not run. That gap once left hold.test.sh dormant.
grep -qF 'bash scripts/repo-hygiene.test.sh' "$repo_root/.github/workflows/actions-ci.yml" \
  && pass "this suite is wired into actions-ci" \
  || fail "repo-hygiene.test.sh is not wired into actions-ci.yml — it would never run"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
