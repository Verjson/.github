---
date: 2026-07-30
id: 20260730T164608Z
title: Stabilize Pulumi workflow assertions
---

Make the Pulumi credential-boundary test search extracted jobs without a
`pipefail`-sensitive producer pipeline, and cover large job blocks that
previously turned successful early matches into intermittent failures (#199).
