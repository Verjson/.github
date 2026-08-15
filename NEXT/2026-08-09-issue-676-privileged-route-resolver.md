---
date: 2026-08-09
issue: 676
title: Stage organization-authoritative privileged route resolution
---

Adds a checkout-free resolver that reads the Verjson privileged lane with a dedicated
read-only token and gives that selector first precedence for regenerated callers. The
existing route remains available only during caller migration; the live privileged
variable remains on the DigitalOcean general fleet.
