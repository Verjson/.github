<!-- Thanks for contributing to verJSON! Please fill out the sections below. -->

## Summary

<!-- What does this PR do and why? Link any related issues, e.g. "Closes #123". -->

## Type of change

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (fix or feature that changes existing behavior)
- [ ] 📝 Documentation
- [ ] 🧹 Chore / refactor / tooling

## How was this tested?

<!-- Describe the tests you ran and how to reproduce them. -->

## Verification

<!-- Do the reviewer's triage for them: pair every claim with proof. -->

- **Evidence it works:** <!-- CI run/job link, test output, or a repro command + result -->
- **Not verified / assumptions:** <!-- the honest boundary — where a reviewer should look -->

## Blast radius & what to check first

<!-- Verification effort should scale with blast radius, not be spent uniformly. -->

- **Blast radius:** <!-- reversible & low-risk (docs / CI / formatting) → skim · logic → review · sensitive/irreversible → deep review -->
- [ ] Touches a **sensitive / irreversible class** (auth/RBAC, migrations, secrets, IAM/OIDC, rulesets/branch protection, destructive) — **always human-reviewed** (see ADR 0007)
- **Check these first (`file:line`):** <!-- pinpoint the load-bearing hunks a human must eyeball; REQUIRED if the box above is checked -->

## Checklist

- [ ] My code follows the project's style and conventions
- [ ] I have performed a self-review of my changes
- [ ] I have added or updated tests where appropriate
- [ ] I have updated documentation where appropriate
- [ ] My changes generate no new warnings or errors

## Screenshots / notes

<!-- Optional: UI changes, context for reviewers, or anything else worth noting. -->
