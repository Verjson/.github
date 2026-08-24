---
date: 2026-08-24
issue: 1054
title: Bind explicit AI-review labels through a separate protected caller
---

Route explicit review labels through a separate protected `pull_request_target:labeled`
caller, reject persistent-label and rerun authority, and bind the caller revision,
delivery source, actor, repository, pull request, and exact head into the verified arm
receipt.
