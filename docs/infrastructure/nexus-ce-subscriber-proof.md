# Nexus CE subscriber acceptance protocol

This protocol implements [ADR 0175](../decisions/0175-enforce-nexus-ce-subscriber-access-at-gateway/README.md)
and tracks [#1186](https://github.com/Verjson/.github/issues/1186). It is a test plan,
not a passed receipt. CI [#134](https://github.com/Verjson/verjson-ci/issues/134) and
CLI [#242](https://github.com/Verjson/verjson-cli/issues/242) provide executable
commands and implementation-specific configuration before the live proof request.

## Isolated fixture

Use a disposable CE instance, actual subscriber gateway and two synthetic subscriber
identities A/B. Record exact image digests, gateway/source revisions, npm version,
configuration digest, host isolation and test-clock mode. Use an isolated issuer
and durable entitlement/session state. Mocked tests must never be labeled live.
Supply secrets through test-owned secret storage, never command-line arguments or
receipts. Use a temporary HOME/npm cache and clean only fixture-owned resources.

Publish one uniquely named scoped package/version through a separate publisher.
Hash the original tarball and preserve its digest in the receipt. Scope A/B to the
fixture; create a second denied package/version to test entitlement isolation.
Exercise real `npm install` with a clean cache through the gateway. Verify that
metadata advertises only gateway tarball URLs and permitted versions, and fetched
tarball bytes match the publisher's original archive.

## Required controls

| Boundary | Positive control | Required negative control |
|---|---|---|
| Expiration | A installs before its bounded deadline | Same grant fails after expiry, including a transfer started before expiry |
| Revocation | A and B independently install | Revoke A; A fails and B still succeeds; measure committed revoke to slow-stream termination against the two-second proof target |
| Entitlement | Authorized package/version installs | Wrong tenant, package/version, stale projection, missing session and unavailable authority deny |
| Scope changes | Fresh issuance can admit newly entitled packages | Narrowing removes access from an old grant; widening cannot add packages/versions to that grant |
| Request handling | Metadata and tarball GET/HEAD work | Encoded traversal, alternate host, spoofed identity headers, generic proxy/admin/write routes and redirects deny |
| Origin isolation | Gateway reads using its backend role | Subscriber reaches no alternate paid-origin port, hostname, group/member or storage path; anonymous/direct reads deny |
| Backend privilege | Backend reads the fixture | Backend publication, overwrite, deletion and administration deny |
| Retry/cache behavior | Authorized retry/range/conditional request succeeds | The same request after revoke or expiry denies; no cached metadata/tarball bypass |
| State/clock failure | Normal time and available current state permit | Clock rollback, expired state and store outage stop access and active streams |
| Attribution | Correlate known A/B requests to artifact/result/bytes | Spoofed request IDs cannot impersonate B; interrupted downloads stay partial; durable audit failure denies |
| Restart | Fresh identity/entitlement checks issue a new grant | All old grants fail after process restart |
| Recovery | Isolated restore serves original bytes after reconciliation | Snapshot predating A's revocation cannot admit A; pre-restore grants fail and restored origin credentials are rotated before exposure |

Test the enforcement operation, not just its caller's timeout. A rejected promise
does not prove that upstream bytes stopped. Capture bounded server/client transfer
measurements and distinguish bytes already sent from bytes released after denial.
Run the timing proof with real clocks as well as deterministic unit boundaries.

## Evidence and activation

The secret-free receipt includes UTC start/end, source/image/config digests, exact
commands, fixture IDs, each control's expected and actual outcome, artifact digests,
revocation/expiry timing, admission/completion correlation, backup identity,
restored-state reconciliation, measured data loss/recovery duration and cleanup.
Record any skipped/unproven control as a failure to accept, not as a passing smoke
test. Preserve receipt integrity and logs independently of the disposable instance.

The CLI PM supplies the exact existing-host deployment diff, secret references,
origin-isolation readback, capacity evidence and rollback before approval of live
DNS/TLS/network/identity/secret changes. Identify already-paid independent backup
and audit storage; if unavailable, leave that acceptance criterion open without
buying capacity. Customer activation and Tequity migration remain separate gates.

The canonical PM reviews both implementation receipts and actual non-production
results before closing #1186. Unit tests, a documentation merge, CI publisher
canaries and Nexus UI reachability cannot substitute for subscriber acceptance.
