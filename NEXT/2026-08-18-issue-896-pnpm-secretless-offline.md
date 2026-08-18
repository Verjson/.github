---
date: 2026-08-18
issue: 896
title: Keep secretless pnpm installs offline
---

Map approved private pnpm resolutions to exact run-local tarballs after transfer verification so the credentialless build job cannot fall back to the private registry while public dependencies remain installable.
