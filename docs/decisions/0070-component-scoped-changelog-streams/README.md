# 0070 — Changelog components are explicit release streams

- **Date:** 2026-08-07
- **Issue:** [#390](https://github.com/Verjson/.github/issues/390)
- **Extends:** [ADR 0038](../0038-canonical-changelog-contract/README.md)
- **Category:** Release architecture
- **Status:** Accepted

## Context

ADR 0038 defines one `NEXT/` store and one immutable snapshot per release, but
it did not identify which independently versioned package owns a fragment.
`verjson-temporal-kit` consequently released Python-only notes in npm snapshots:
selection defaulted to every fragment, and metadata could not express a stream.
The snapshot is immutable, so a silent cross-package selection is permanent.

Separate `NEXT/<stream>/` directories would make discovery recursive and change
every path invariant. Declaring the contract single-package would document the
failure without making multi-package repositories safe. Issue #390 option 1 is
the smallest extension that makes the existing flat store expressive.

## Decision

A canonical fragment may declare an optional `component`:

```yaml
component: python
```

Components are release-stream identifiers, not paths or package-manager names.
They are 1–64 lowercase characters, may contain letters, digits, `.`, `_`, and
`-`, and must begin and end with a letter or digit. Slashes, traversal, empty
values, uppercase aliases, and leading/trailing punctuation are invalid.

Selection is fail-closed:

- no selector means the **unscoped** stream only; repositories whose fragments
  omit `component` behave exactly as before;
- `--component NAME` selects only fragments whose component equals `NAME`;
- explicit `--fragment` values narrow the selected stream and can never pull a
  fragment from another component;
- an empty selected stream is an error and writes no snapshot, commit, or tag.

Validation and `check-pr` remain repository-wide. Every scoped and unscoped
fragment is validated, identities remain globally unique, and an ordinary pull
request cannot consume a fragment from any stream. Rendering follows the same
selection rule as release: default rendering is unscoped, while
`render-next --component NAME` previews one component.

Each release still writes exactly one `CHANGELOG/<version>.md` and tags its
exact commit. The caller owns the version/tag namespace (`v1.2.3`,
`python-v1.2.3`, or another valid existing convention); the contract does not
derive versions from component names. Unselected streams remain in `NEXT/`.

The reusable release workflow and generated caller expose an optional
`component` input and pass it as one quoted argument. Generated renderers expose
only `--component NAME` and `--as-released`; they do not provide a general
subcommand escape hatch.

## Consequences

- Single-package adopters need no metadata or caller change.
- A scoped fragment cannot silently leak into the default release.
- Multi-package adopters must dispatch each stream explicitly and use
  non-colliding version/tag names.
- Global identity uniqueness still makes overlapping issue ownership visible;
  related fragments in other streams use `refs`.
- A typo in a component is a distinct stream rather than a match. Validation
  bounds its syntax, while release requires exact selection and fails on an
  empty stream.

## Rejected alternatives

- **Default to all scoped and unscoped fragments.** Backward-looking but unsafe:
  it preserves the silent permanent leak this decision exists to stop.
- **Make component mandatory.** Breaks every single-package repository for no
  benefit; absence already names the unscoped default stream.
- **Use nested `NEXT/<stream>/` directories.** Larger path-model migration,
  recursive discovery, and more complex `check-pr` semantics than option 1
  requires.
- **Infer component from changed paths or package manifests.** Repository layout
  is not a stable release identity and inference can silently select the wrong
  immutable notes.
