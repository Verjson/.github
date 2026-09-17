---
date: 2026-09-17
issue: 1381
title: Fail the organization ruleset audit when a required status check pins no producer App
---

The organization ruleset conformance audit now reports every required status
check whose ruleset entry declares no producer `integration_id`. An unbound
context can be satisfied by a status posted from any App that happens to use the
same name, which is the ADR 0024 class the ADR 0184 gate's provenance half exists
to close.

The finding is attributable per ruleset and context and is printed alongside, not
instead of, a release-authorization finding, so neither masks the other. The audit
also validates the `required_status_checks` rule shape, so a malformed parameters
block fails closed rather than raising.

Applying the pending `core-checks-actions` binding is an organization ruleset
mutation held for human application; see ADR 0190.
