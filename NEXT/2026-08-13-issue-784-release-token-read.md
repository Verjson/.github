---
date: 2026-08-13
issue: 784
title: Keep the release job token read-only
---

The canonical release workflow and generated snapshot caller now keep `GITHUB_TOKEN` at Contents read while the repository-scoped release App token alone performs the protected atomic push.

Behavioral and mutation tests reject restoring the obsolete Actions-token write grant. ADR 0099 records why the App-backed push no longer depends on it, and ADR 0038 points reciprocally to that narrowly scoped supersession.
