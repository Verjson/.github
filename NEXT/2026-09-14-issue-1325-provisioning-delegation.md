---
date: 2026-09-14
issue: 1325
impact: minor
title: Define owner-approved delegation for agent-operated provisioning
---

An owner can now delegate a reviewed provisioning plan to a named executor through a grant document. `config/provisioning-delegation-contract.json` defines the issuer/executor boundary, the effect vocabulary and its owner-gated subset, the immutable `Verjson/verjson-ci` contract pin, evidence, expiry and revocation requirements; `scripts/provisioning-delegation-validate.py` turns a grant into an authorization receipt offline, with no network call and no credential read. One reviewed grant authorizes every action it lists without per-call reconfirmation. Model output, unattended mode, an executor-authored approval field and any unrecognized field are rejected, and every owner-gated effect needs its own consent record with a GitHub-hosted reference and approvers excluding the executor.

`config/app-role-custody-inventory.json` extends the custody record from the three environment-bound roles to all seven owned roles, each with storage, trust, rotation and role-specific positive, negative and insufficient proof. A target may request only its role's permitted effects and must declare exactly the catalog permission ceiling, which is how review/merge/release separation, read-only ruleset audit, isolated runner control and the supersession enablement gate are enforced mechanically. The contract ships as `defined-not-activated`: merging it authorizes nothing until an owner changes that status in a reviewed pull request. ADR 0177 records the decision; `docs/provisioning-delegation.md` is the runbook.
