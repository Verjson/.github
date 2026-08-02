---
date: 2026-07-30
id: 20260730T215122Z
title: Report workflow-change auto-merge holds as successful
---

Workflow-file pull requests now leave the privileged merge path successfully with a
clear human-review notice instead of reporting the intentional no-merge policy as a
failed CI check. The review gate excludes its trusted dispatch and privileged merge
continuations from repository CI evaluation, preventing circular authorization while
ordinary repository check failures remain fail-closed.
