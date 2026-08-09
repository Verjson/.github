---
date: 2026-08-08
issue: 646
title: Mint AI authorization App tokens by client ID
summary: Migrate pinned GitHub App token actions to the supported client-id input while retaining numeric App identity verification.
---

Trusted authorization workflows now fail closed on a missing or malformed
`AI_REVIEW_CLIENT_ID` and pass it only to pinned token-minting actions. The numeric
`AI_REVIEW_APP_ID` remains the receipt, check-run, and App identity trust boundary.
