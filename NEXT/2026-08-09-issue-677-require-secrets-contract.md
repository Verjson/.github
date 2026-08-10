---
date: 2026-08-09
issue: 677
title: Restore the privileged merge secrets contract
---
Wire the split review and privileged merge workflows into a mutation-tested CI contract that keeps the broad merge token away from PR validation and keeps the terminal merge path restricted to immutable trusted verifier material.
