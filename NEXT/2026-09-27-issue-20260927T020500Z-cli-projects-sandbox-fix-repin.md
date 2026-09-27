---
date: 2026-09-27
id: 20260927T020500Z
impact: patch
title: Repin the cli-projects required workflow to the hosted sandbox-provisioning fix (#1423)
---
`cli-projects-package-surface-required.yml` calls `node-ci-protected.yml@4a08c756547ccaf8977eda692e14eff56fddaf15` (#1636) on both lanes, and `config/cli-projects-package-surface-ruleset.json` records the currently active image (`ebe574b`) as the previous workflow so ruleset 21830367 can be rotated to this commit. The consumer `ci.yml` is regenerated to the same commit before rotation because admission compares its bytes.
