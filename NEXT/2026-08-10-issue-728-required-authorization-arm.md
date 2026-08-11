---
date: 2026-08-10
issue: 728
title: Require the trusted authorization arm before dispatching AI review
---

Make the trusted `pull_request_target` authorization arm the deployable replacement for the ruleset's dispatch-only AI workflow, with a fail-closed fleet credential audit and a non-vetoing human path.

ADR 0091 records the one-for-one migration order. The live ruleset remains unchanged until every governed repository passes the new read-only App installation, secret, variable, trigger, and exclusivity checks.
