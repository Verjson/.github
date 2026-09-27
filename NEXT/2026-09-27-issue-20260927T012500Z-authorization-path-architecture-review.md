---
date: 2026-09-27
id: 20260927T012500Z
impact: patch
title: ADR 0206 records the authorization and privileged-merge path review and untangles the dependency chain (#1363)
---
ADR 0206 gains a dated amendment describing the five hops of the authorization path (property enrollment, `gate-rearm`, `ai-review-merge`, `ai-privileged-merge`, App custody) and adjudicating the tracker chain `#1363 ← #1401 ← #1500 ← verjson-cli#281`: only `#1401 → #1363` was real coupling, now bound to the specific prerequisite verjson-agents#417; the `#1500 → #1401` and `verjson-cli#281` edges were over-linking and are removed. The migration transaction is unchanged; its prerequisites are reordered so the privileged-merge canaries (#1500) proceed in parallel.
