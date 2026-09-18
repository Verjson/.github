---
date: 2026-09-18
issue: 1421
impact: patch
title: Name the token permission Gate A needs, and carry the guidance diff that adopts it
---

`assert-mergeable-head.sh` reads the base ref's ruleset to establish its required set, and
`gh api` exits 1 for an authorization refusal and a transient 5xx alike — so an adopter
whose token could not read that endpoint got the same opaque fault as a retryable outage
and no way to tell which. The ruleset read now inspects the HTTP status and refuses
401/403/404 with a message naming the token as the cause and stating the access required:
ordinary repository read (fine-grained Metadata read, classic `repo` for a private
repository, `contents: read` in Actions), never `administration`. That requirement is now
stated in the script's own header, together with the fact that GitHub masks an
unauthorized read of a private repository as 404. Gate A remains unevaluable — never
degraded — when the read is refused.

Adds `docs/merge-gate-guidance-proposal.md`, carrying the proposed organization-guidance
change that replaces the bare `statusCheckRollup` all-conclusions predicate with the
script and documents what each exit code means at the point of use, reviewable without
access to the guidance repository. `scripts/assert-no-deferred-checks.sh` is unchanged.

Capturing that stderr to inspect the status also redirected it away from the caller on the
success path, so a `200` carrying a rate-limit or deprecation warning would have been
discarded where it previously reached the operator. The replay is therefore unconditional
on the capture being non-empty rather than a consequence of having failed, and the status
match reads the last line of a paginated stream — the refusal that ended the walk — rather
than an earlier page's. Both are now asserted, as is the fact that a transient failure
replays `gh`'s own diagnostic, which is the only thing separating a 502 from a 500. The
permission text is stated once in `permission_help()` and quoted into the refusal instead
of being restated in the header.
