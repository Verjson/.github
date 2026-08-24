---
date: 2026-08-24
issue: 1054
title: Bind explicit AI-review labels to trusted delivery receipts
---

Route explicit review labels through a protected `issues:labeled` bridge, reject
persistent-label and rerun authority, and bind the delivery source, actor, repository,
workflow revision, pull request, and exact head into the verified arm receipt.
