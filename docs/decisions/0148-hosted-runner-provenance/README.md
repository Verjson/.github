# 0148 — Produce deployable runner provenance on hosted infrastructure

- **Date:** 2026-08-27

## Status

Accepted

## Context

Issue #1142 found that canonical runner images and their release manifest were
built and attested by the same `self-hosted,general` fleet that consumes them.
Runner admission correctly rejects those attestations with
`--deny-self-hosted-runners`. A compromised or unhealthy fleet must not be able
to establish its own deployment provenance.

## Decision

Deployable container preparation, private dependency acquisition, publication,
image and SBOM attestation, candidate-manifest attestation, and release promotion run on the fixed GitHub-hosted
`ubuntu-24.04` image. The setting is not an organization variable that can
silently resolve back to a self-hosted lane. Pull-request validation may still
use the configured CI lanes, and bounded package retention remains operational
work that does not establish artifact provenance.

Admission continues to require `--deny-self-hosted-runners`, exact workflow and
contract commits, exact source commits, and immutable subject digests.

## Consequences

Deployable releases require independent hosted-builder capacity and may be
slower than fleet-local builds. A new immutable release is required; existing
self-hosted attestations are not grandfathered or re-signed.
