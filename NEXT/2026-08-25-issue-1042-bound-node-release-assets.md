---
date: 2026-08-25
issue: 1042
impact: minor
title: Add bounded immutable assets to generated Node releases
---

Generated Node release callers can opt into attaching committed repository files, with traversal, symlink, type, collision, count, and size checks binding every uploaded byte to the immutable release tag.

ADR 0134 records the release-authority boundary. Existing callers emit an empty asset list and retain their current behavior.
