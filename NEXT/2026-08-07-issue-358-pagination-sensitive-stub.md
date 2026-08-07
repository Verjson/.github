---
date: 2026-08-07
title: Make the workflow-files hold test actually depend on pagination
issue: 358
---

`require-secrets.test.sh` labelled a case "paginated workflow changes beyond 100 files", but
its `gh` stub returned the whole already-filtered fixture whatever flags it was given. So the
case never depended on `--paginate`, and **removing pagination from the production call left
the test green** — the guard would have missed a workflow file after file 100 and allowed a
privileged auto-merge where policy requires a human hold, with a passing test on top.

The stub now behaves like `gh api` does: without `--paginate` it returns page 1 only, so
entries past the first 100 are reachable only when the flag is passed. Fixtures of 100 or
fewer entries are unaffected, which is why no other case in the file changes.

Verified by mutation rather than by inspection. Against the unmutated tree the suite passes;
with `--paginate` deleted from `ai-privileged-merge.yml`'s `workflow_files_changed`:

```
FAIL - workflow change did not produce a successful no-merge human hold
```

No production behaviour changes here — the workflow already paginated correctly. What changed
is that the test can now tell.
