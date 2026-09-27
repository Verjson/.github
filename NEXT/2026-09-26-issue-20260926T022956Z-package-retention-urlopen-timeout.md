---
date: 2026-09-26
id: 20260926T022956Z
impact: patch
title: Bound package_retention.py's GitHub API calls with a socket timeout
---

`GitHubPackages._request` called `urllib.request.urlopen` with no timeout, so a
stalled connection to the GitHub API blocked the retention job indefinitely —
observed directly on a real `container-release.yml` run (`verjson-git-runners`
run 36209652761): the "Retain three numbered image releases" step produced
zero output for 30 minutes before the job's own external timeout cancelled
it, rather than the script itself failing fast with a diagnosis. No package
version was deleted before the cancellation (confirmed against live package
state), but the retention step never completed.

Bound every request to 30 seconds and report a clear `RetentionError` instead
of the underlying `urllib.error.URLError` when a call stalls, so a future hang
fails closed with a reason in the log rather than silently consuming the whole
job's timeout budget.
