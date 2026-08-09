---
date: 2026-08-09
issue: 20260809130500
title: Finish issue 622 Actions CI source isolation
---

Actions CI now checks out each matrix group into a run-unique source directory
before copying it into job-temporary storage, preventing a co-located runner's
checkout cleanup from removing another group's scripts during setup.
