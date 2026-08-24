---
date: 2026-08-24
issue: 1035
impact: major
title: Use organization-neutral canonical CI configuration names
---

Canonical workflows, generators, tests, and documentation now use role-based `CI_*` variables and neutral deployment/release secret names, so adopters no longer configure CI using the authoring organization's name.

ADR 0123 separates portable GitHub configuration from operator-specific App identities and internal process variables. Verjson retains legacy live variables for immutable historical pins while generated callers roll forward at one contract SHA.
