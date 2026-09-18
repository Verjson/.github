---
date: 2026-09-18
issue: 1450
title: Cover every ci-gate script by a stated rule instead of the .test. suffix
impact: patch
---

The #1320 orphan detector in `scripts/actions-ci-groups.test.sh` exists so a gate cannot
pass locally while running nowhere in Actions. It found its candidates by the `*.test.sh`
suffix, so `scripts/ci-gate/hub-changelog-validate.sh` — a gate that is not a test — was
invisible to it: deregistering it from `scripts/actions-ci-groups.tsv` left the entire
suite green with the gate running nowhere. PR #1446 pinned that one registration from
inside the gate's own test, which protects one file and signals nothing about the next.

The candidate set is now stated rather than inferred from a filename:

> Every tracked `*.sh` or `*.py` file under `scripts/ci-gate/` is a gate script and must
> be reachable in Actions, unless it is declared a library module in
> `scripts/actions-ci-groups.test.sh` with a stated reason. Reachable means named as a
> command argument in `scripts/actions-ci-groups.tsv`, in the `hosted-compatibility-tests`
> run step, or anywhere in a tracked workflow or composite action under `.github/`.

Adding a file under `scripts/ci-gate/` therefore has two honest outcomes: register it
where Actions runs it, or declare it a library with a reason. Four files are declared —
the `scripts/ci-gate/conformance/` modules, which are imported and never invoked — and a
declaration that goes stale, because its path stopped being tracked or became registered
after all, reddens the same check. Candidates come from `git ls-files`, because the index
is what Actions checks out.

Deregistering `hub-changelog-validate.sh` now reddens `actions-ci-groups.test.sh` itself
and names the file, so #1446's per-file pin is removed; its one further assertion, that
the row sits in the `platform` group, moved to that file's load-bearing command list.

The rule proves a gate is *named* on an Actions execution path, not that the path
executes: a script named only by a workflow whose triggers never fire still counts as
reachable. That residual, and the rejected alternatives, are recorded in
[ADR 0193](docs/decisions/0193-every-ci-gate-script-is-a-gate-unless-declared-a-library/README.md).

Follow-up from the independent review, after the above merged. Three corrections, no
behavior change:

- The claim that the declaration list "cannot quietly rot into a suppression list" was
  stronger than the code. The review proved it by adding a real, executable, unregistered
  gate script *and* declaring it a library — the suite passed silently. The staleness
  assertions bound decay, not misuse: whether a file is genuinely a library is not a
  computable property, so a real gate parked in that list passes. The control for that is
  review of a diff to the list, which is why the list lives in the gate file rather than
  in a data file. ADR 0193 and the gate's own comment now say that instead.
- The stated residual named never-firing triggers and always-false `if:`, but not the
  shape that actually exists in this tree: a script named only by a `sparse-checkout:`
  entry or an `env:` value while its invocation is deleted still reads as reachable,
  because the match is against the whole workflow text.
- A tracked workflow missing from the worktree raised a bare traceback instead of the
  stated failure its sibling helper raises. It now exits naming the path and the cause.
