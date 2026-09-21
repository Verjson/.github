# 0199 — Authorization checks fail without review App credentials

- **Date:** 2026-09-21
- **Status:** Accepted
- **Related:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md), [ADR 0112](../0112-arm-authorization-checks-reach-a-terminal-state/README.md), [ADR 0195](../0195-an-indeterminate-authorization-answer-is-not-a-permissive-one/README.md)
- **Issues:** [#1498](https://github.com/Verjson/.github/issues/1498)
- **Supersedes (authorization check ownership only):** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md)

## Context

An empty `AI_REVIEW_APP_PRIVATE_KEY` can prevent the review App from minting a token after an authorization check has started, leaving the check pending. The credential being validated is also the credential previously required to finish that check. A failure in the credential therefore could not reliably produce a terminal result.

## Decision

GitHub Actions owns creation and terminal updates for `AI review authorization`. The dedicated review App remains the sole author of AI approval reviews and does not receive `checks:write`. The workflow validates the resolved private key as an RSA PEM before publishing a receipt or dispatching paid review work. If validation fails, an always-run finalizer completes the exact check as failure and names `AI_REVIEW_APP_PRIVATE_KEY` and the configured environment in its check output.

The check remains bound to its exact head, repository, PR, arm run and attempt, nonce, and details URL. New receipts record the Actions check App identity. Receipt verification continues to accept older receipts that bind the check to the review App, and completion, privileged-merge, and post-merge readers accept either identity only for the exact receipt-bound authorization check. This compatibility ends through a separately tracked migration after in-flight runs and adopters have moved to the new contract.

Every generated reusable-workflow caller grants the minimum `checks:write` permission required by the caller-owned `GITHUB_TOKEN`; the called workflow cannot elevate that token. Terminalizers can only fail a matching in-progress authorization check. They never grant success.

## Consequences

- Missing or malformed review credentials fail visibly on the PR without minting an App token or dispatching a model review.
- The Actions App identity is part of the new receipt contract; readers retain a receipt-bound compatibility path for older AI App-owned checks during rollout.
- A caller missing `checks:write` fails before it can create the authorization check, so generator contract tests protect every generated caller.
- The review App retains only the permissions needed to read repository content and author the required approval review.
