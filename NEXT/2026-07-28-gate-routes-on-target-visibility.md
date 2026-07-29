- `ai-review-merge.yml`: the gate job now routes on the resolved
  `TARGET_REPO`'s visibility (preflight output `target_private`), not the
  dispatching repo's — an operator re-gating a private repo from public
  `Verjson/.github` no longer lands the review on the public/isolated path;
  unresolved visibility fails closed to the self-hosted `gate` pool. The
  org-aware non-Verjson → `ubuntu-24.04` branch from #175/ADR 0030 is
  preserved, and both `runs-on` comments drop the retired ADR-0016
  meta-lane self-gate description. (#168, #170)
