---
date: 2026-09-10
issue: 1284
impact: patch
title: Reject invalid ADR generator arguments and clean verification temporaries
---

The canonical ADR index generator rejects unknown modes and extra arguments with exit 2 before changing files. Verification and regeneration now clean their rendered temporary files on success or failure, while preserving the existing index on rendering errors and retaining locale-independent sorting.
