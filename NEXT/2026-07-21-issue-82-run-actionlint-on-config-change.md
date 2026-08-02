---
date: 2026-07-21
issue: 82
title: Run actionlint when its runner-label config changes
---

Include `.github/actionlint.yaml` in actionlint's pull-request and main-push path
filters, with an extraction-based regression test for both events. Runner-label
allowlist edits can no longer bypass lint and drift from workflow `runs-on`
usage. Closes #82.
