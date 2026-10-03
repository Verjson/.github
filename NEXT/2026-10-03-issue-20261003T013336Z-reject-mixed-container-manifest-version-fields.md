---
date: 2026-10-03
id: 20261003T013336Z
refs: 1667
impact: minor
title: Reject mixed container manifest version fields
---

Candidate schema v2 records now reject v3 publication timestamps and destination receipts.
V2 records remain readable when they match their original shape; v3 remains required for
promotion.
