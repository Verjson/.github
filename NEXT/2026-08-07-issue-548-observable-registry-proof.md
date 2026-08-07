---
date: 2026-08-07
issue: 548
title: Assert observable registry proof for publication reruns
---

Generated release contracts now enforce the authenticated package identity and integrity evidence consumed by restart reconciliation without prescribing a redundant registry identity command.

Authorization and network failures still fail closed at the explicit GitHub Packages state read, while the contract independently requires the publication credential and exact name, version, and integrity comparisons.
