---
date: 2026-08-07
id: 20260807T170000Z
title: Refuse unsigned reusable-caller merge provenance
---

Privileged merge no longer accepts a reusable workflow reference as proof the
gate produced an attestation. Consumer-authored callers remain supported for
review but require human merge until signed workflow provenance exists.

The exact `.github` workflow-id and organization-ruleset-required workflow
shapes remain trusted. No organization ruleset or policy was changed.
