---
date: 2026-08-21
issue: 974
impact: patch
title: Require the checkout-credential exemption's consuming step to run after the checkout
---

`audit_checkout_credentials` (`scripts/ci-gate/changelog-caller-contract.test.sh`)
verified a named consuming step exists and still performs the justifying remote
git operation, but not that it runs after the checkout it excuses. A reordered
workflow could keep the exemption valid by name while the persisted credential
was actually consumed by an earlier, unrelated step. The audit now also checks
step index ordering, with a new tamper test confirming a reordered consumer
re-flags the checkout.
