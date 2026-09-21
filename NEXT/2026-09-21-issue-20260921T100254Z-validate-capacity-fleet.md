---
date: 2026-09-21
id: 20260921T100254Z
impact: patch
title: Validate runner fleet capacity evidence
---

The deployment controller now validates the host-export lane, complete runner roster, and per-runner availability against the reported capacity, using `@verjson/cli-cloud@1.1.0` for [#1451](https://github.com/Verjson/.github/issues/1451).

The protected runner-fleet production environment still needs operator-provisioned host-observation credentials and pins before live host acceptance can be claimed.
