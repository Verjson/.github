---
date: 2026-08-20
issue: 953
impact: patch
title: Skip the #950 write-denial test under a root runner
---

The #950 regression test denies write access via `chmod 555` on a directory,
but a root runner ignores directory permission bits, so `mktemp`/`mv` could
still succeed there and falsely fail the test. Skip that one case (with a
`pass` noting why) when `id -u` is `0`; every other case is unaffected.
