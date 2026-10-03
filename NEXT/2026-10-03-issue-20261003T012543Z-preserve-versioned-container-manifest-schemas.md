---
date: 2026-10-03
id: 20261003T012543Z
refs: 1667
impact: minor
title: Preserve versioned container manifest schema validation
---

Published candidate and release schemas now validate historical v2 records and current
v3 manifests. V3 requires publication timestamps and verified registry destination
receipts; release promotion continues to reject v2 candidates that lack this evidence.
