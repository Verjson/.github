---
date: 2026-08-06
issue: 452
title: Dismiss stale gate reviews after a finding is fixed
---

Dismiss an old-head `github-actions[bot]` changes-requested review before a
new-head non-blocking verdict turns green, allowing corrected pull requests to
recover without manual intervention.

The original finding stays visible in the timeline, while human, current-head,
and unbound reviews remain untouched. Review API failures fail closed. This
change stacks on the terminal-verdict correction from #441 and refines ADR
0058.
