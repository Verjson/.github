---
date: 2026-08-22
issue: 1003
title: "docs(adr): correct ADR 0114's staleness direction to match the implementation"
---

ADR 0114 defined staleness as "pinned SHA is not an ancestor of the introducing
commit," but the implemented check is `is_ancestor(introduced_at, pinned_sha)`
— the reverse direction. Corrected the prose to "the introducing commit is not
an ancestor of the pinned SHA" so a future implementation can't invert the
check by trusting the ADR's wording.
