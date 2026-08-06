---
date: 2026-08-06
issue: 466
title: 'fix(changelog): a release dispatched off the default branch fails instead of reporting success'
---

`changelog-release.yml` guarded the default branch with a job-level `if:`. GitHub
reports a skipped job as successful to its caller, so dispatching a release from
any other ref produced a green run that released nothing — no snapshot, no tag, no
publish — and a caller's `publish` job then ran against a tag that was never
created.

The check is now the job's first step and exits non-zero, naming the offending
ref. Behaviour on the default branch is unchanged. Adopters that hand-rolled a
local `preflight` job around this can drop it.
