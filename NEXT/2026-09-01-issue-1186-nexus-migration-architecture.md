---
date: 2026-09-01
issue: 1186
impact: patch
title: Replace the Cloudsmith decision with a gated Nexus migration architecture
---

Supersede the unprovisioned Cloudsmith rollout decision with a self-hosted Sonatype Nexus Repository architecture that defines trust boundaries, operational ownership, non-production proof, byte-identical dual publication, recovery, rollback, and explicit human gates.

The production baseline is Nexus Repository Pro subject to current capability proof and procurement approval. The decision does not provision infrastructure, incur spend, mutate DNS/TLS or secrets, migrate a customer, retire GitHub Packages, or authorize irreversible npmjs.org publication.
