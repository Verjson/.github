---
date: 2026-08-28
issue: 1100
impact: minor
title: Generate secretless private artifact builds
---

Let generated artifact releases acquire explicitly approved private packages outside repository build hooks and route multi-OS builds through exact ADR 0103 lane expressions.

The generated contract keeps package credentials in a lifecycle-disabled acquisition matrix, hands exact-attempt dependencies to credentialless build legs, and rejects ambiguous runner expressions or typo-like variable literals.
It also binds the fail-loud OS-lane preflight byte-for-byte so a consumer cannot retain its labels while bypassing selector validation, using the native SHA-256 utility on both Linux and macOS adopters.
