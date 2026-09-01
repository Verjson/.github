---
date: 2026-09-01
issue: 1224
impact: patch
title: ADR 0058's live org-audit evidence is now dated and marked as a snapshot
---

The `#1221` amendment to ADR 0058 quoted a live org-wide audit result
(`conformant=25 nonconformant=3 unclassified=6 unaudited=0 skipped=63`) with no
date attached, which reads as a current fact rather than a one-time measurement
that will drift as repositories are added, reclassified, or brought into
conformance.

The evidence line now states it was run 2026-08-31, as of that change, and says
explicitly that it is a historical snapshot proving the gate worked as designed
on that date — not a tracked figure kept current, and not the org's present
state. A reader who needs the current numbers should re-run the audit rather
than trust the line.

Found as an AI-review follow-up on PR #1222
(`docs/decisions/0058-github-waits-for-checks-not-the-gate/README.md:620`).
