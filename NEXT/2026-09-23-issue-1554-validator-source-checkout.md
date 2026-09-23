---
date: 2026-09-23
issue: 1554
impact: patch
title: Bind AI review validators to the canonical source
---

Generated AI-review callers now pass the immutable Verjson/.github contract revision used by their reusable-workflow edge, so consumer reviews check out policy and authorization validators from that canonical commit rather than pairing the hub repository with the consumer head.

The reusable workflow validates the contract revision before checkout, propagates it across verifier jobs, and revalidates it before every downstream canonical checkout so an always-running completion job cannot fall back to a mutable ref after failed preflight. Caller mutations reject consumer-head, stale-pin, and malformed substitutions while existing receipt-bound exact-head authorization remains unchanged; ADR 0044 records the generated-caller equivalence boundary.
