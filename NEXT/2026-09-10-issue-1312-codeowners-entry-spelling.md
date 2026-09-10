---
date: 2026-09-10
issue: 1312
impact: patch
title: Require canonical CODEOWNERS entry spelling
---

Check the exact .github directory and CODEOWNERS filename spelling so case-insensitive lookups cannot falsely pass canonical ownership conformance. Preserve existing fallback checks without scanning unsupported locations.
