---
date: 2026-08-09
issue: 675
title: Isolate Actions CI source checkouts
---

Actions CI now checks out each matrix group and the actionlint job into
run-unique source directories before execution or job-temporary copying. This
prevents a co-located runner's checkout cleanup from removing another job's
workflows or group runner during setup.
