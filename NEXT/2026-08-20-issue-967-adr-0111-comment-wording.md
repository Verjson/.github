---
date: 2026-08-20
issue: 967
impact: patch
title: Align the ADR 0111 inline comments with its actual blast-radius tradeoff
---

The inline comments on `RENOVATE_COMPATIBILITY_PAT`'s usage claimed it carries
"only the read access this job needs, not a broader organization credential" —
understating the blast radius ADR 0111 itself already documents accurately: the
PAT is the owner's own credential with full org-wide read access, not a
least-privilege token. Corrected the comments to match.
