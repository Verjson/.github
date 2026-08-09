---
date: 2026-08-09
issue: 685
title: Serialize promotion-retry workflow names safely
---

Allow generated terminal-promotion retry callers to name punctuation-rich GitHub workflows such as `Integration (event-hub e2e)`. The generator now emits compact JSON as a YAML flow sequence, rejects control characters and GitHub expressions at the boundary, and shell-quotes the canonical JSON in its regeneration command.

Adversarial contract coverage proves parentheses, colons, slashes, quotes, and YAML-shaped text remain data while newlines and expression payloads are rejected.
