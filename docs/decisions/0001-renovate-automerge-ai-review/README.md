# 0001 — Renovate auto-merge + org-wide advisory AI review

- **Date:** 2026-07-13
- **PR:** Verjson/renovate-config#1 (preset change); org ruleset edited via API
- **Category:** repo rulesets / branch protection, dependency automation

## Context

Renovate PRs could never auto-merge: the `main-protection` org ruleset requires 1
approving review, code-owner review, and last-push approval on every PR, so ~75
dependency PRs piled up across the org. The advisory AI review workflow
(`Verjson/.github/.github/workflows/renovate-ai-review.yml`) existed but was not
wired to run in any repo.

## Decision

1. **Org ruleset `main-protection` (id 18098028):**
   - Added bypass actors: `OrganizationAdmin` (always) and the Renovate GitHub App
     (`Integration` id 2740, always) so Renovate can merge its own PRs past the
     review requirements.
   - Added a required-workflow rule: `.github/workflows/renovate-ai-review.yml`
     from `Verjson/.github@main` must pass on every PR org-wide. The workflow
     no-ops (exit 0) for non-Renovate PRs and when `ANTHROPIC_API_KEY` is absent,
     so it never blocks human work.
2. **`Verjson/renovate-config` preset:** `platformAutomerge: false` — Renovate
   merges its own PRs only after all branch checks are green. GitHub-native
   auto-merge would fire immediately for a bypass actor, before CI completes.
3. **All repos:** `allow_auto_merge=true`, `delete_branch_on_merge=true`.

## Effective ruleset diff

```diff
 {
   "name": "main-protection",
+  "bypass_actors": [
+    { "actor_type": "OrganizationAdmin", "bypass_mode": "always" },
+    { "actor_id": 2740, "actor_type": "Integration", "bypass_mode": "always" }
+  ],
   "rules": [
     ...existing deletion/non_fast_forward/linear_history/pull_request rules...,
+    { "type": "workflows", "parameters": { "workflows": [
+      { "repository_id": 1269388380, "path": ".github/workflows/renovate-ai-review.yml", "ref": "refs/heads/main" }
+    ]}}
   ]
 }
```

## Consequences

- Non-major Renovate updates land automatically after green CI plus a 3-day
  stability window; majors still require Dependency Dashboard approval.
- Every Renovate PR gets an advisory Claude review comment once the
  `ANTHROPIC_API_KEY` org Actions secret is set
  (`gh secret set ANTHROPIC_API_KEY --org Verjson --visibility all`).
- The Renovate app can bypass all main-branch rules; its scope of action is
  limited to the PRs it authors.
