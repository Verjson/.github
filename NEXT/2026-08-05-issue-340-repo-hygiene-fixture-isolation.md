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
