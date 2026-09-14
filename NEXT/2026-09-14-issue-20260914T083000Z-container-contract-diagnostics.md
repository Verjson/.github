---
date: 2026-09-14
id: 20260914T083000Z
title: Report which container-deployment contract assertion failed, and what it expected
impact: patch
---

`scripts/gen-container-deployment.sh contract-test` now generates a contract test that
names the failing assertion and prints its expected and observed values, instead of
exiting 1 with no output. A delivery leg on `Verjson/verjson-git-runners#207` had to
bisect the generated script by hand to discover which precondition was unmet, because
every assertion was a bare `test`, `jq -e`, or `grep -q` under `set -e`.

The generated script gains three diagnostics surfaces. `assert_digest` reports the
pinned artifact path with both sha256 digests when a byte-for-byte pin drifts. The
deployment-config validation re-evaluates each `container-deployment.json` precondition
individually and reports every field that failed with its expectation and observed
value. An `ERR` trap is the backstop: any assertion added later that still fails bare is
reported by script path, line number, and exit status, so the diagnosability guarantee
does not decay as the contract grows.

No assertion was relaxed or removed, and the ERR trap re-exits with the original status,
so the test fails closed exactly as before. `scripts/container-deployment-contract.test.sh`
now pins both properties: it asserts that byte drift in a pinned python module is
rejected *and* that the rejection names the module and both digests, and that an invalid
deployment config is rejected *and* that the rejection names the offending fields. This
repository owns no generated copy of these artifacts — the only adopter set lives in
consumer repositories, which pick the change up on their next regeneration at a contract
ref containing it.
