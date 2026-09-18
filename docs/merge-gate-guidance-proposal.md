# Proposed guidance change — direct pre-merge callers to `assert-mergeable-head.sh`

**Status:** proposed, not filed. **Target:** the organization's agent-guidance
repository (`verjson-agents`), file `rules/workflow.md`, section `## Pull Requests`.
**Hub record:** [#1421](https://github.com/Verjson/.github/issues/1421). **Decision:**
[ADR 0184](decisions/0184-merge-gates-assert-execution-not-absence-of-red/README.md).

The guidance repository is outside this work's PR-ownership boundary, so this file
carries the change as reviewable text. Nothing here has been applied to that repository,
and no branch was created in it. The text it replaces is quoted verbatim below so that a
reviewer with no access to that repository can judge the diff on its own.

## Why this exists

[#1364](https://github.com/Verjson/.github/issues/1364) landed
`scripts/assert-mergeable-head.sh`, its test, its `merge-gate` registration, and ADR 0184.
What it did not land is adoption. Neither that script nor `scripts/assert-no-deferred-checks.sh`
is invoked by any workflow; both are agent- and human-facing tooling run by whoever is about
to merge. So what actually decides merges is whatever the guidance tells an agent to run,
and that is still the bare predicate ADR 0184 was written to replace.

Every defect ADR 0184 enumerated is therefore still live at the point of use:

- one opaque `false` covers four materially different head states;
- the required set is inferred from the head rather than read from the base ref's ruleset,
  so a head that reports only advisory checks satisfies `all(...)` over them;
- the cheapest repair for an opaque `false` is to widen the accepted-conclusion list, which
  is precisely how [`Verjson/verjson-cli#251`](https://github.com/Verjson/verjson-cli/issues/251)
  recurs once ADR 0178's `deferred-ci` exists.

The sharpest single case: a head with checks created but **no entry at all** for a required
context. `assert-mergeable-head.sh` fails closed on it (correct — ADR 0024; this is a
merge-time assertion, not a watcher). The one-liner returns `true` for it whenever the
entries that *do* exist are passing. That difference is the whole point of the replacement
and it currently reaches nobody.

## Current text (verbatim, `rules/workflow.md` lines 200–206)

```markdown
- **Before an `--admin` merge, assert every check's conclusion programmatically — don't
  eyeball a printed status table.** Skimming output you just printed yourself, especially
  while batching several merges back to back, is exactly how a `FAILURE` conclusion gets
  missed. Run something like:
  `gh pr view N --json statusCheckRollup --jq '[.statusCheckRollup[].conclusion] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")'`
  and only merge if that command's output is literally `true`.
```

## Proposed replacement

```markdown
- **Before an `--admin` merge, assert the head is mergeable with
  `scripts/assert-mergeable-head.sh` from `Verjson/.github` — don't eyeball a printed
  status table, and don't substitute a bare all-conclusions predicate.** Run
  `bash scripts/assert-mergeable-head.sh <owner/repo> <pr-number>` and merge only on exit
  `0`, whose entire output is `true`. It needs ordinary repository read access
  (fine-grained: Metadata read; classic: `repo` for a private repository; in Actions:
  `contents: read`) — not `administration`. Every nonzero exit names what to do, so act on
  the code without opening the script:
  - `2` — usage error: a malformed `owner/repo` or PR number.
  - `3` — **Gate A**: a context the *base ref's ruleset* requires is absent, pending, not
    passing, or was published by an app the ruleset does not bind. Absent fails closed
    (ADR 0024) and is never satisfied by its own absence. Investigate the named context.
  - `4` — **Gate B**: the head was *deferred*, so nothing on it was verified — no test,
    lint, type check, or repository-local contract guard ran (ADR 0178). Wait for the
    release-age gate to clear and Renovate to rebase, or force a real run with
    `workflow_dispatch`. Do not merge.
  - `5` — **Gate C**: some other check is pending or non-passing, listed by name. Usually
    a judgement call rather than a hard blocker.
  - `1` — the assertion could not be **evaluated** (an API failure, or a token that cannot
    read the base ref's ruleset). This is not a green light: fix the cause and re-run.
  Never widen the accepted-conclusion list or relax a gate to make a head look green —
  that edit is exactly how `Verjson/verjson-cli#251` recurred. See ADR 0184.
```

## The change as a patch

Replace lines 200–206 of `rules/workflow.md` (the "Current text" block above, in full)
with the "Proposed replacement" block above, in full. Both are reproduced verbatim, so
the substitution is mechanical; no surrounding bullet in `## Pull Requests` changes, and
no other file in that repository is touched.

## What the proposal deliberately does NOT change

- **`scripts/assert-no-deferred-checks.sh` is untouched.** ADR 0184 ships the new script
  *beside* it rather than retracting it; it remains correct for its narrower question and
  its existing callers keep working. This is an addition to what agents are told to run.
- **The `watch_pr_checks` fallback monitor (`rules/workflow.md`, "Portable PR check
  monitor") keeps its rollup predicate.** It is a *watcher* — it answers "have the checks
  settled yet", and it must treat `NO_CHECKS` and `PENDING` as non-terminal rather than
  fail closed. `assert-mergeable-head.sh` is a merge-time assertion and fails closed on
  exactly those states. Swapping it in there would turn a poll loop into an immediate
  refusal. The two tools answer different questions and both should exist.
- **No workflow is made to invoke either script**, per #1421's fourth acceptance
  criterion. Wiring one into CI is a further, separately-argued change.

## Notes for whoever files this

- **Size budget — measure before filing.** `tests/test_guidance_size.py` in that
  repository caps `rules/workflow.md` at 36,000 characters
  (`WORKFLOW_CHARACTER_BUDGET = 36_000`). It measured 34,142 characters at the time of
  writing, so there were 1,858 characters of headroom. The quoted current text is 501
  characters and the replacement is 1,714, a delta of **+1,213** — landing at 35,355 and
  leaving only 645 characters spare. It fits, but barely, and any growth in that file
  since this was written may have closed the gap. Re-measure before filing. If it no
  longer fits, trim the explanatory prose rather than dropping an exit code: a reader
  being able to act on a failure *without opening the script* is the point of the change.
- **Surface coverage.** The bare predicate appears only in `rules/workflow.md`, which
  Claude Code alone loads automatically. The other generated guidance views (`CANON.md`,
  `AGENTS.md`, `GEMINI.md`, `OPENCODE.md`) do not carry it, so agents on those runtimes
  receive no pre-merge assertion at all today. That gap is real, but it is a separate
  question from this diff and is not proposed here.
- **Path assumption.** The replacement says "from `Verjson/.github`" without pinning a
  distribution mechanism, because adopters currently obtain hub scripts by several routes
  and ADR 0184 explicitly defers adoption sequencing to the contract-distribution
  decision. If a canonical vendoring path is settled first, pin it here.

## Filing status

Not yet filed against the guidance repository. #1421's third acceptance criterion — "the
proposal is filed against the guidance repository and linked from this issue" — remains
open, and is why the pull request carrying this file says `Part of #1421` rather than
closing it.
