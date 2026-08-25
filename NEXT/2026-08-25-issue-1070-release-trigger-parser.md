---
date: 2026-08-25
issue: 1070
title: 'fix(changelog): reject ambiguous release trigger mappings'
---

Make generated changelog contracts reject duplicate YAML-equivalent release trigger keys, aliases, merge keys, flow ambiguity, malformed mappings, and any drift from the exact generated `workflow_dispatch` input schema instead of accepting the first readable `on` key.
