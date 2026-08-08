---
date: 2026-08-08
issue: 609
title: Give Node CI a job-writable changelog cache
---

Scopes the changelog tool cache used by Node CI to the runner's job-temporary
directory and clears the persistent override for the contract's isolated test
fixtures, so cold-cache tests do not depend on writable runner state.
