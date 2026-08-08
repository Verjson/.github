---
date: 2026-08-08
issue: 630
title: Give generated Node releases a job-writable changelog cache
---

Generated Node release verification and publication now override persistent runner cache paths with a cold, job-scoped changelog tool cache beneath `runner.temp`.

This keeps repository release hooks and builds usable on self-hosted runners whose host-level changelog cache is intentionally not writable by ordinary jobs.
