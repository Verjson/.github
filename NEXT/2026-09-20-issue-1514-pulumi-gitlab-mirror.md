---
date: 2026-09-20
issue: 1514
title: Choose Pulumi for the GitLab mirror kit
impact: patch
---

Accepted ADR 0197 supersedes the Terraform implementation choice for the GitLab mirror kit. It preserves published v1/v2 manifest compatibility, requires a versioned Pulumi manifest artifact, and keeps live migration separately authorized.
