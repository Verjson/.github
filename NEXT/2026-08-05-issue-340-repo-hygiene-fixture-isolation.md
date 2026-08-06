---
date: 2026-08-05
issue: 340
title: Keep the hygiene suite inside its sandbox, and its fence parser inside the fence
---

`scripts/repo-hygiene.test.sh` was destructive to run in a live checkout. Its
`fixture()` helper returned the fixture path by printing it, so every caller was
a `$(...)` capture of whatever the helper's own commands printed. A reused
fixture name (`nested`, used at two cases) re-entered an already-committed
fixture, `git commit` found nothing to stage and reported "nothing to commit" on
**stdout**, and that report came back prepended to the path. The caller then ran
`mkdir -p "$path/docs"` — creating a newline-named directory in the repository
root — and `git -C "$path" add -A && git commit`, which walked up into the HOST
repository and swept the runner's in-progress work into a stray commit titled
`document under docs/`. Observed three times in one session (#340), and it also
meant the `docs/` edge case never exercised the behaviour it claimed to cover:
`git ls-tree` is prefix-relative, so checking the junk path reported "no root
README" for the wrong reason (#393).

The path now comes back in `$fixture_dir` rather than on stdout, a reused
fixture name is refused, and every fixture git call goes through `fixture_git`,
which rejects any directory that is not a git repository under the suite's own
`mktemp -d`. `scripts/ci-gate/repo-hygiene-sandbox.test.sh` stands up a
disposable host repository from the tracked tree, runs the suite inside it, and
asserts `git status --porcelain` is empty and `HEAD` is unmoved — the regression
that reproduced the stray commit before the fix.

That containment is a property of the path, not of the string spelling it, so it
is checked on the resolved path (`cd … && pwd -P`). A `"$tmp"/?*` prefix match
was satisfied by `$tmp/../<name>` and by a symlink under `$tmp` pointing
anywhere, and both then satisfied `[ -d "$dir/.git" ]` too; each was demonstrated
moving a second disposable repository's `HEAD`, and each now aborts the suite.
`fixture()` also refuses a path-shaped name, because `git init -q "$tmp/$name"`
runs before any call reaches `fixture_git`. The sandbox guard gained the half a
disposable host cannot see: it pins the real checkout's `HEAD` and working tree
as well, since an escape by absolute path leaves the host byte-identical while
mutating the tree the test runs from. Its own setup is checked rather than
silently discarded, and every `HEAD` read uses `rev-parse --verify` — plain
`rev-parse HEAD` prints the literal string `HEAD` on an unborn branch, so the
before/after comparison passed vacuously on a host whose setup commit never
happened. The `docs/` case pins the reported verdict and not just the exit code:
every other way that fixture can break also exits 1, which is the "passes for the
wrong reason" mode #393 is about. (`cp --parents -t` in the guard is GNU
coreutils only — the CI runner and the development environment.)

`scripts/repo-hygiene.sh` also counted headings that never leave a code fence
(#352): it toggled one boolean on any three-backtick or three-tilde line, so the
inner ``` of a ```` block read as the close and everything after it counted as
rendered sections. A README whose entire body is one code block could report
compliant while visibly answering none of the required questions. The parser now
remembers the opening fence character and run length, and closes only on a run
of the same character at least as long with no info string after it — measured
character by character, because mawk is the default awk on the runners. Indented
fences, tildes, and longer-than-opening closures all still work, each with a
test; the three fence bypasses were verified red against the previous parser.

Fence and comment state are not independent, so the order they are evaluated in
is the behaviour. Comments were scanned first, which meant an unterminated
`<!--` inside a fenced HTML example — the ordinary way to show comment syntax in
a README — opened a comment that ran to end of file and blanked the whole parse:
a fully compliant README was reported as having no purpose section. Per line the
parser now resolves an already-open comment, then fence state, then scans for
`<!--`, so a `<!--` inside a fence is inert while a fence line inside an open
comment is still consumed by the comment branch first. Both directions have a
test, and the second was verified by mutation — reordering the two makes it fail.
Rendered output over the 224 tracked markdown files in this repository is
byte-identical before and after.
