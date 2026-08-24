---
date: 2026-08-24
issue: 1017
impact: patch
title: Keep the audited Claude action pin synchronized
---

Renovate now updates the Claude review action and its independently audited SHA in one dependency group, preventing otherwise-safe digest updates from leaving merge-gate CI red.

The exact upstream change from `24dcd50c0568f0fc9e9211213a4fd2d9eb15c4e0` to `c81e3bc69d1b18badbb63ba39581218f02421678` was reviewed as a direct-child version-only bump of Claude Code and its Agent SDK.
