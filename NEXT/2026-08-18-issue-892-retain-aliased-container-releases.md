---
date: 2026-08-18
issue: 892
title: Retain aliased numbered container releases
---

Allow a numbered container release to share its digest with non-version aliases while
continuing to reject multiple numbered tags on one digest. Retained aliased indexes now
participate in recursive OCI graph protection, so their untagged child manifests remain
protected from cleanup.
