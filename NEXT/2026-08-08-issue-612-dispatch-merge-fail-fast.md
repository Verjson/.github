---
date: 2026-08-08
issue: 612
title: Stop merge dispatch waits after prerequisite failure
---

- Release routed merge-dispatch runners as soon as a prerequisite check reaches a terminal failure, while retaining the failed check names, conclusions, and diagnostic links in the job log.
