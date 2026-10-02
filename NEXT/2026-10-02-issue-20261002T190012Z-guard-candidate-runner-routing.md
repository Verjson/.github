---
date: 2026-10-02
id: 20261002T190012Z
impact: minor
title: Guard candidate runner routing
---

For #1679, disable caller-selected runners on pull requests and allow that exact guarded selector only on the three jobs in the canonical candidate workflow. Add a negative policy fixture for the same expression in an unrelated workflow. Align the contract fixture with GitHub's canonical repository identity so PR validation exercises the same identity comparison as Actions.
