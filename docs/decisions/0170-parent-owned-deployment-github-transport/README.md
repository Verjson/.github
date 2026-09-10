# 0170 — Parent-owned deployment GitHub transport

- **Date:** 2026-09-10
- **Status:** Accepted

## Context

[Issue #1281](https://github.com/Verjson/.github/issues/1281) identifies missing
deployment evidence and representative probe transport blocking runner #197 and
the #629 acceptance path. A child inheriting deployment mutation credentials
would violate the evidence boundary. CLI v0.29.1 inventory mutates host locks
and its existing read-only attestation output is insufficient. Current CLI main
has no replacement; [CLI #504](https://github.com/Verjson/verjson-cli-cloud/issues/504)
is a native prerequisite of #1281.

## Decision

Deliver a generated, standard-library GitHub broker with strict complete
transaction requests and receipts independently of host lifecycle implementation.
The parent explicitly supplies a dedicated role App JWT; the broker validates
the live App/installation permissions and mints a single-repository token.
Manifest verification uses only read authority and exact raw asset bytes.
Canary dispatch uses the existing immutable canonical workflow contract with
independently authenticated run/job/artifact bindings and a durable intent before
the sole dispatch write. Ambiguous writes are reconciled, never blindly retried.

Private keys belong only in protected main-only role environments under ADR 0166;
there is no broad-secret fallback or new caller key forwarding. The JWT issuer,
environment provisioning and broad-copy removal are rollout prerequisites, not
features silently supplied by the broker. Host export remains owned by CLI #504;
we neither duplicate its private SSH paths nor call mutating inventory in dry-run.
The broker rejects that unavailable operation explicitly.

## Consequences

This is partial upstream capability, not a working deployment path. Existing
controller and workflow activation waits for supported host export, complete
parent integration and resume reconciliation, reviewed authority and host trust,
capacity and live acceptance. The concrete integration obligations and operator
contract are in [the transport guide](../../deployment-github-transport.md).
Mocked adversarial tests cover protocol boundaries, and generated artifact
integrity detects consumer drift. This separation avoids coupling deployment to
unsupported private lifecycle paths at the cost of a staged delivery. ADR 0162's
portable core and forge adapters remain the future GitLab boundary; no speculative
universal fleet controller is introduced.
