---
date: 2026-08-17
issue: 842
impact: patch
title: Fail early or select a reachable database endpoint on isolated runners
---
Canonical Node CI now verifies its database endpoint before consumer commands and
automatically uses the exact container bridge endpoint when Docker host loopback
is isolated from the runner.

Callers can require `loopback` or `container` with `db-host`, and can consume the
selected `${DB_HOST}` and `${DB_PORT}` placeholders without reimplementing the
canonical container lifecycle. ADR 0021 records the bounded runner-topology
amendment.
