---
date: 2026-08-07
issue: 388
title: Bind documented changelog metadata to the recommended immutable pin
summary: Changelog adoption docs now distinguish v2.2.0 capabilities from the recommended immutable commit, and CI executes that pin against every advertised metadata key.
---

The changelog README and migration guide now state that `v2.2.0` predates
`refs` and `summary`, while the recommended immutable commit supports all six
documented metadata keys and every documented generator mode. Consumer
examples no longer resolve mutable `main`.

`contract-pin.test.sh` reads the README capability table and executes the exact
pinned engine against both identity forms, failing if any advertised key is
rejected, ignored, or left unexercised. No release was cut or dispatched.
