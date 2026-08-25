# 0137 — Cut `v1.0.0` across the pre-1.0 `@verjson/*` packages

- **Date:** 2026-08-25
- **Status:** Accepted
- **Issue:** [#1088](https://github.com/Verjson/.github/issues/1088)
- **Related:** [ADR 0038](../0038-canonical-changelog-contract/README.md), [ADR 0071](../0071-changelog-impact-governs-version-bumps/README.md), [ADR 0102](../0102-explicit-impact-for-new-changelog-fragments/README.md), [ADR 0108](../0108-bound-package-retention-to-three-stable-releases/README.md)

## Context

Eighteen `@verjson/*` packages are published below `1.0.0`. Below `1.0.0`, SemVer assigns
the breaking-change role to the **minor** position, and the caret range follows: `^0.1.3`
admits `0.1.4` but not `0.2.0`.

The consequence is that a `0.x` package cannot ship a guardrail. Any change significant
enough to warrant a minor bump is, by construction, invisible to every consumer on a caret
range. A fix published as `0.2.0` reaches nobody pinned at `^0.1.x`, and nothing signals
that they did not receive it. The organization has been publishing corrections into a
version space where corrections do not propagate.

Above `1.0.0` the range binds: `^1.0.0` accepts the whole major, so a patch reaches
consumers and a major announces itself. That is the property being bought.

It is also a liability, and it is the reason this decision is coupled to a readiness bar
rather than being a bulk version bump. After `1.0.0`, a breaking change mislabelled as a
patch reaches consumers *silently*. That is not hypothetical here:
[`Verjson/verjson-authn#244`](https://github.com/Verjson/verjson-authn/issues/244) — between
`1.0.1` and `1.0.3`, the published `CodeStore` port replaced an optional member with a
required one and shipped it as a patch. It was found by a downstream consumer. The
mechanism was mundane: the changelog engine defaults `impact:` to `patch` when the field is
absent, so omitting it produces a patch release of a breaking change with no error
anywhere.

Cutting seventeen more packages to `1.0.0` without first installing detection would
multiply that failure mode by seventeen.

## Decision

**Cut `v1.0.0` for every `@verjson/*` package still below it, gated on a published
readiness bar, released in dependency order, and followed by a deliberate consumer-bump
phase.**

### The readiness bar

The bar is [`docs/v1-readiness/README.md`](../../v1-readiness/README.md) in this
repository. It is the authoritative checklist; per-repository prep issues reference it **at
an immutable commit SHA**, never at `main`, so the bar a repository was audited against
stays readable after the bar moves.

Every item in it is grounded in a defect observed in this organization during 2026-08-25,
not in general 1.0 advice. Summarised, a package may cut `1.0.0` only when it has: a
published-`.d.ts` surface conformance check in CI that fails closed; a complete `exports`
map verified by real resolution against a packed tarball; no internal range that excludes
a sibling's `1.0.0`; compatibility matrices expressed as majors rather than exact versions;
the current changelog contract landed; an explicit `impact:` on every unreleased fragment;
a rehearsed dispatch-only release path; a deliberate vulnerability sweep; and an accurate
public API and README.

Two of those deserve restating here because they are the ones a bulk wave would skip.

**The type-surface check must exist before the cut, not after the first escape.** Its
reference implementation is
[`Verjson/verjson-authn#246`](https://github.com/Verjson/verjson-authn/pull/246), open at
the time of this decision. **Landing #246 is a prerequisite of the wave**, because it is the
only implementation that handles the three traps that make a naive version of the check
silently useless — `skipLibCheck: true` turning the resolution guard into dead code,
TypeScript's `... N more ...` elision blinding a textual comparison, and a shallow CI
checkout leaving `origin/<base>` unresolvable so the gate widens instead of failing.

**`impact:` must be explicit on every fragment the release will consume.** Its absence is a
defect, not a default. `scripts/changelog.py` falls back to `patch`, and `check-pr` does not
enforce the field on fragments already present on the base — only `validate --base` rejects
a newly added one. A repository that reaches its cut with implicit-patch fragments in
`NEXT/` will compute the wrong version.

### Release ordering

Ordering is **derived from the dependency graph, and is a rule rather than a preference**:
a package cannot cut `1.0.0` while a consumer's range excludes `1.0.0`, because the
consumer's install fails `ERESOLVE`. Every range widening under readiness item 3 must be
released *before* its target cuts.

Derived from the manifests on 2026-08-25 (`@verjson/*` edges only; `@verjson/cli`,
`@verjson/cli-cloud`, and `@verjson/cli-projects` read from GitHub, the rest from local
checkouts of `main`):

**Layer 0 — no runtime or peer edge on any other in-wave package. Release first, in
parallel.**

`tsconfig` · `eslint-config` · `identity-contracts` · `ai` · `infra` · `email` ·
`customer-lifecycle` · `graphql-conventions` · `pg` · `temporal-kit` · `cli-projects`

**Layer 1 — depends on layer 0 only.**

`authz` (peer `identity-contracts`) · `oidc-claims-middleware` (peer `identity-contracts`) ·
`identity-lifecycle` (runtime `identity-contracts`) · `leads` (runtime `identity-contracts`;
its `authn` peer is already `^1.0.0`) · `ai-gguf` (peer `ai`) · `cli-cloud` (runtime `infra`)

**Layer 2.**

`cli` (runtime `cli-cloud`, `cli-projects`)

### The foundational packages are not the ones the layering suggests

"Foundational first" is commonly read as `tsconfig`, `eslint-config`, `identity-contracts`.
The derived graph refines that, and the refinement changes the risk ranking:

| Package | Dependents | Edge kind |
|---|---|---|
| `@verjson/tsconfig` | 22 | **all `devDependencies`; zero runtime or peer** |
| `@verjson/eslint-config` | 5 | **all `devDependencies`** |
| `@verjson/identity-contracts` | 7 distinct packages, 9 edges | **5 runtime, 2 peer**, 2 dev |

`tsconfig` has the largest dependent count in the organization and the **lowest** blast
radius, because a `devDependency` never enters a consumer's install graph. Its `1.0.0`
breaks 22 repositories' *own CI* until each bumps its devDependency — a scheduling
constraint, not a consumer-facing break. Release it first for that reason, not because it
is on anyone's critical path.

**`@verjson/identity-contracts` is the genuinely critical node.** It is the only in-wave
package consumed at runtime by packages already past `1.0.0` — `authn` 1.0.3,
`observability` 1.1.0, and `payments` 2.1.1 — none of which this wave otherwise touches.
Worse, `authn` (`^0.2.2`), `observability` (`^0.2.1`), and `authz` (`^0.2.0`) already fail
to resolve the published `0.3.0`. Those ranges are broken **today**, before the wave starts.
`identity-contracts` therefore requires the widest range-widening pass and the most careful
sequencing of any package in the set.

### The one cycle

There is exactly one cycle among `@verjson/*` packages, and it is not a runtime cycle:

```
@verjson/identity-contracts --dev--> @verjson/authz@^0.8.1
@verjson/authz             --peer--> @verjson/identity-contracts@^0.2.0
```

**The runtime-and-peer graph is acyclic.** The back edge is a `devDependency`, so it is not
a release blocker. Resolve it by cutting `identity-contracts` `1.0.0` first — its `authz`
devDependency may float or stay pinned at `0.8.x` for that release — then widening `authz`'s
peer range and cutting `authz` against it. Do not attempt to release the two simultaneously.

### Two phases, not one

**Publishing `1.0.0` does not reach consumers.** `^0.x` ranges do not accept `1.0.0`, so
every consumer stays on its last `0.x` until someone deliberately bumps the range. A package
that publishes `1.0.0` and stops has changed nothing for anybody — which is the same
propagation failure this decision exists to fix, merely relocated.

- **Phase one — publish.** Each package clears the readiness bar and cuts `1.0.0` in
  dependency order.
- **Phase two — bump consumers.** Each consumer's dependency range is deliberately moved to
  `^1.0.0` and released. This includes the three packages already past `1.0.0` that consume
  `identity-contracts`, and this repository's own
  `contracts/container-deployment-cli/package.json:6`, which pins `@verjson/cli-cloud@0.28.1`
  exactly.

Phase two is where the wave actually delivers value. Treating phase one as completion is
the predictable way for this effort to produce no consumer-visible result.

## Consequences

**Retention will delete `0.x` versions faster than usual, and that is intended.** GitHub
Packages retention keeps the three most recent stable versions
([ADR 0108](../0108-bound-package-retention-to-three-stable-releases/README.md)). Every
package in the wave publishes at least once, and most twice — a range widening, then the
`1.0.0`. Any consumer left un-bumped after phase two will begin hitting `E404` on fresh
installs as its pinned `0.x` ages out.

That is a forcing function, not a defect. The remedy is to bump the consumer, never to
re-pin a vanished version, ask for one to be restored, or propose widening retention for a
stale consumer. Diagnose before acting: an `E404` is equally consistent with a stale
lockfile pin, an authentication failure, and a registry outage, and should be classified as
retention only after authenticated verification over the same credential path shows the
requested version absent while current versions are readable.

**Compatibility matrices become fragile during the wave.** An exact-version matrix leg
naming a `0.x` sibling has a short remaining life once that sibling starts publishing.
[`Verjson/verjson-authz#124`](https://github.com/Verjson/verjson-authz/issues/124) already
reddened two unrelated pull requests this way. Readiness item 4 requires majors instead;
during the wave, that item is the difference between a scheduled release and an unrelated
repository's CI going red.

**The bar costs real work per repository.** Seventeen audits, each installing a type-surface
check, verifying an `exports` map by resolution, widening ranges, and rehearsing a release,
is substantially more effort than seventeen version bumps. That cost is the decision: the
alternative is seventeen packages in which a mislabelled patch now propagates silently.

**Some repositories will fail the bar and stay at `0.x` longer.** That is the correct
outcome. A package that cannot detect its own breaking changes should not be making a
stability promise.

## Rollback

A published version cannot be unpublished, so this decision is not reversible per package
once its `1.0.0` is dispatched. What remains reversible is the **wave**: it can be halted
between packages at any layer boundary, leaving already-cut packages at `1.0.0` and the
remainder at `0.x`. A package cut in error is corrected by a further release under normal
SemVer rules — `1.0.1` for a fix, `2.0.0` for a break — never by editing a released
`CHANGELOG/<version>.md` snapshot, which is immutable.

Consumers not yet moved in phase two are unaffected by a halt, since their `^0.x` ranges
never resolved the `1.0.0` in the first place — until retention removes their pinned
version, at which point the remedy is still to bump forward.
