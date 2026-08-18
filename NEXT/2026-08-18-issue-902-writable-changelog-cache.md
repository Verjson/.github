---
date: 2026-08-18
issue: 902
title: Make changelog contract caches runner-portable
---

Allocate Node CI and release changelog tool caches in uniquely owned workspace
directories so cold contract resolution remains writable even when a shared
runner exposes a protected temporary root.
