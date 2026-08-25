---
date: 2026-08-25
issue: 1074
impact: patch
title: Reject malformed short pnpm integrity pins
---

Treat every pnpm version containing a Corepack `+sha512.` qualifier as an integrity pin and require the exact 128-character lowercase hexadecimal digest, including malformed values short enough to match the general Renovate version grammar.
