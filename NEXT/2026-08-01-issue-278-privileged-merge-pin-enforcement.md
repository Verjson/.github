---
date: 2026-08-01
issue: 278
title: Privileged merge verifies which revision of itself is executing
---

ADR 0042 required consumers to pin the privileged merge at `@main` and recorded the
SHA-pinning exposure as closed. Nothing enforced it. The generator and the pin test both
run in `Verjson/.github`; the caller file lives in the **consumer's** repository, so
neither binds anything downstream, and the runtime anchor pins the *gate*'s revision rather
than this workflow's own. `ai-privileged-merge.yml` could have been executing from a fork
with every other guard passing.

It now resolves its own executing revision — `job.workflow_sha` for a reusable call,
falling back to `github.workflow_sha` for `.github`'s own `pull_request_target` run — and
requires it to be reachable from `Verjson/.github@main` before touching the admin token. A
fork, a side branch, a rewritten history, or a revision never on `main` is rejected outright.

Acceptance is reachability rather than equality, deliberately: `main` may advance between
the caller's dispatch and this step, and a strict check would turn that race into a red
merge check on a correctly merged pull request. `behind_by` is checked alongside `status`
because `ahead` alone also describes a diverged history sharing an ancestor.

**One exposure stays open and is recorded as open** in
[ADR 0043](../docs/decisions/0043-privileged-merge-verifies-its-own-revision/README.md): a
caller pinned to an *older commit that is still on main* is reachable, so it passes.
Telling that apart from the benign race needs dispatch-time state this job does not have,
so the run warns and names both readings instead of claiming a closure it cannot deliver —
which is the mistake this change exists to correct.

Seven mutations against the new check, all caught. The existing privileged-merge suites now
supply the workflow identity, so dropping the check fails eleven assertions.
