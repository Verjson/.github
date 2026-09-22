---
date: 2026-09-22
issue: 1506
impact: patch
title: Report canonical changelog contract drift across adopters
---
A weekly read-only fleet report now names adopter pins that differ from the current canonical contract in a private caller run, with an immutable inventory artifact for follow-up. Incomplete scans are shown in the report and fail the workflow so missing access cannot appear as a clean fleet.

The inventory uses the reusable workflow commit selected by its immutable caller pin, so callers cannot choose code that receives the existing organization-wide `contents: read` compatibility App token; that App does not write to consumer repositories.
