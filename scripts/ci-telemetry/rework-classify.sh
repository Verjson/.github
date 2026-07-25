#!/usr/bin/env bash
# Pure classifier for the rework reconciler (issue #33). Reads a JSON array of
# raw merged-PR records on stdin and emits an enriched array: each record gets a
# `change_category`, `ai_authored` flag, and a `rework_signal` tier. No network,
# no side effects — so it is fully unit-testable from fixtures
# (scripts/ci-telemetry/rework-classify.test.sh).
#
# Category order is sensitivity-first (auth/migration win over app/ci/docs) so a
# change that touches a sensitive area is never masked by a lower-risk match —
# it must not under-attribute blast radius. `fix_same_area` is the MVP
# approximation of the ticket's "fix touching the same top-level area within N
# days": here it is any conventional fix/revert not already caught by a revert
# marker or an explicit issue reference. That approximation is intentional and
# documented in docs/rework-telemetry.md.
set -euo pipefail

jq '
  def paths: [.files[]? | ascii_downcase];
  def msgs: ([.commit_messages[]?] | join("\n") | ascii_downcase);
  def title_lc: ((.title // "") | ascii_downcase);
  def body_lc: ((.body // "") | ascii_downcase);

  def has_re($re): (paths | any(test($re)));
  def all_docs: (paths | (length > 0) and all(test("\\.md$|^docs/|/docs/|^readme|^license|^changelog|^next")));

  def category:
    if   has_re("(^|/)(authn|authz|rbac|abac|oidc|claims|iam)([/._-]|$)") then "auth"
    elif has_re("(^|/)migrations?/|\\.sql$|(^|/)migrate([/._-]|$)")        then "migration"
    elif has_re("pulumi|terraform|\\.tf$|(^|/)helm|(^|/)k8s|kustomize|dockerfile|(^|/)infra([/._-]|$)") then "infra"
    elif has_re("\\.tsx?$|\\.jsx?$|\\.py$|\\.go$|\\.rs$|(^|/)src/")         then "app"
    elif has_re("\\.github/workflows/|(^|/)scripts/ci|actionlint|\\.github/actions/") then "ci"
    elif all_docs then "docs"
    else "other" end;

  def ai_authored: (msgs | test("co-authored-by:[^\n]*claude"));

  def is_fix:            (title_lc | test("^(fix|revert)(\\([^)]*\\))?!?:"));
  def is_revert_title:   (title_lc | test("^revert(\\([^)]*\\))?!?:|^revert \""));
  def has_revert_body:   ((msgs | test("this reverts commit")) or (body_lc | test("this reverts commit")));
  def has_fix_ref:       (is_fix and ((title_lc | test("(fixes|closes|resolves)\\s+#[0-9]+")) or (body_lc | test("(fixes|closes|resolves)\\s+#[0-9]+"))));

  def rework_signal:
    if   (is_revert_title or has_revert_body) then "revert"
    elif has_fix_ref                          then "explicit_fix_ref"
    elif is_fix                               then "fix_same_area"
    else null end;

  def enrich: {
    number,
    change_category: category,
    ai_authored: ai_authored,
    rework_signal: rework_signal,
    post_merge_ci_fail: (.post_merge_ci_failed // false),
    file_overlap_only:  (.file_overlap_only // false),
    review_rounds:              (.review_rounds // 0),
    changes_requested:          (.changes_requested // 0),
    commits_after_first_review: (.commits_after_first_review // 0),
    time_open_s:                (.time_open_s // 0)
  };

  map(enrich)
'
