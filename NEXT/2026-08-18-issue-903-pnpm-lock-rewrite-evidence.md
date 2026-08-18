---
date: 2026-08-18
issue: 903
refs: 904, 905
title: Exercise the secretless pnpm lock rewrite with a real frozen install
---

The canonical Node workflow now bounds PyYAML parsing to YAML 1.2 boolean semantics, reports surplus transfer digests precisely, and exercises successful, failure, surplus, and lock-restoration paths with a real credentialless frozen pnpm install fixture. This also resolves follow-up issues #904 and #905.
