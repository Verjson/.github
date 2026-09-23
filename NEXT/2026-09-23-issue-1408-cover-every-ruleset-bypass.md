---
date: 2026-09-23
issue: 1408
title: Cover every organization ruleset bypass with a reviewed contract
impact: patch
---

Make the organization-wide ruleset audit reject bypass actors on any uncontracted
ruleset, independent of branch targeting, and require every contracted ruleset to
match its exact reviewed actor image without treating actor ordering as policy.
