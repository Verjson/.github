---
date: 2026-08-07
title: Let the generated render guard tolerate only an emptied NEXT/, not every failure
issue: 399
---

The contract test emitted by `scripts/gen-changelog-caller.sh contract-test` guarded its
render block on the renderer's exit status alone:

```sh
if "$renderer" >"$work/rendered" 2>/dev/null; then
  ... assert every fragment renders with its metadata linkage ...
else
  echo "ok - no unreleased fragments to render (a release consumed them)"
fi
```

The tolerance is meant to be narrow — `render-next` exits non-zero once a release has consumed
`NEXT/` — but keyed on the status, **every** renderer failure reported that same `ok`: an
unreachable contract fetch, a digest mismatch, a malformed fragment, a missing `python3`, the
#398 argv ceiling. Each is a broken adopter announcing a clean release, and `2>/dev/null`
discarded the only sentence that said which. Duplicate #419 reported the same thing.

The tolerated state is now decided from the **tree** rather than the status: an emptied `NEXT/`
is observable directly, so a non-zero exit with renderable fragments still present is a
failure, and the captured stderr is printed instead of thrown away.

Both directions are pinned in `scripts/ci-gate/changelog-caller-contract.test.sh`, because
each alone is satisfiable by a wrong fix:

- A broken renderer with fragments present must **fail**, must surface the renderer's own
  diagnostic, and must say why this is not the post-release case. Against the unfixed
  generator this case reports `a broken renderer with fragments still in NEXT/ reported
  success` — the defect, reproduced.
- An emptied `NEXT/` must **still** tolerate a non-zero exit. Without this, "fail on every
  non-zero exit" would pass the first case and break every adopter the moment they released,
  which is the regression the guard was added to prevent. The fixture asserts the release
  really emptied `NEXT/` first, so the case cannot pass vacuously.

The fixture breaks the renderer the way a real adopter breaks — non-zero exit with a
diagnostic on stderr — rather than by deleting it, which would trip the earlier
"is not executable" check and pass for the wrong reason. It also has to carry the
`CONTRACT_REF` line, since the emitted suite verifies the pin before it ever renders; without
that the suite died early and the render guard was never reached. The first version of this
test did exactly that and passed for the wrong reason until the fixture was corrected.
