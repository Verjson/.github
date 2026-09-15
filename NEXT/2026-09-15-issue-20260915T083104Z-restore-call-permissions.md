---
date: 2026-09-15
id: 20260915T083104Z
impact: patch
title: Restore explicit read-only permissions on nested policy calls
---
Restore the explicit `actions: read` and `contents: read` permissions on
reusable-workflow caller jobs. GitHub supports this caller keyword, and
retaining it makes the intended token boundary explicit while #1356 remains
under investigation.
