#!/usr/bin/env bash
# Pure renderer for the rework reconciler (issue #33). Reads a concatenated
# aggregate array (all repos) on stdin and the human-owned thresholds file as
# $1, and emits the weekly-summary Markdown. It PROPOSES (flags buckets over
# their human-set warn floor with enough sample); it never enforces anything —
# observe-and-report only (ADR 0006). Pure; unit-tested from fixtures
# (scripts/ci-telemetry/rework-report.test.sh).
set -euo pipefail

thresholds="${1:?usage: rework-report.sh <thresholds.json>  (aggregate JSON on stdin)}"

jq -r --slurpfile cfg "$thresholds" '
  ($cfg[0]) as $c
  | ($c.min_sample // 10) as $min
  | ($c.rework_rate_warn) as $warn
  | def thr($cat): ($warn[$cat] // $warn.default // 1);
    (.[0]) as $first
  | [ .[] | select(.sample_size >= $min and .rework_rate > thr(.change_category)) ] as $breaches
  |
  "## AI-work rework — weekly reconciler\n"
  + (if $first
     then "\nWindow: **" + $first.window_start + " → " + $first.window_end + "** (" + ($first.window_days | tostring) + " days)\n"
     else "\n_No merged PRs found in the window for any configured repo._\n" end)
  + "\n_Observe-and-report only (ADR 0006): this **proposes**, it never changes a merge or verification gate. Low-precision `overlap` is directional and excluded from the rework rate. Treat small samples as directional (buckets below `min_sample = " + ($min | tostring) + "` are never flagged)._\n"
  + "\n### ⚠️ Threshold proposals\n\n"
  + (if ($breaches | length) == 0
     then "_None this window._\n"
     else ([ $breaches[]
             | "- **" + .repository + " · " + .change_category + " · " + (if .ai_authored then "AI" else "human" end)
               + "** — rework_rate `" + (.rework_rate | tostring) + "` > warn `" + (thr(.change_category) | tostring)
               + "` (sample " + (.sample_size | tostring) + "). Consider heavier human review for this category, or promote a recurring cause into a lint rule (#43)." ]
           | join("\n")) + "\n" end)
  + "\n### Per category × authorship\n\n"
  + "| repo | category | authored | merged | rework | rate | rev | fixref | fixarea | postCI | overlap* | rounds_p50 | open_s_p50 | chgreq_p50 | commits_p50 | sample |\n"
  + "|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n"
  + (if (. | length) == 0 then "" else
     ([ sort_by([.repository, .change_category, .ai_authored])[]
        | "| " + .repository
          + " | " + .change_category
          + " | " + (if .ai_authored then "AI" else "human" end)
          + " | " + (.merged_count | tostring)
          + " | " + (.rework_count | tostring)
          + " | " + (.rework_rate | tostring)
          + " | " + (.rework_by_signal.revert | tostring)
          + " | " + (.rework_by_signal.explicit_fix_ref | tostring)
          + " | " + (.rework_by_signal.fix_same_area | tostring)
          + " | " + (.rework_by_signal.post_merge_ci_fail | tostring)
          + " | " + (.file_overlap_only | tostring)
          + " | " + ((.review_rounds_p50 // "–") | tostring)
          + " | " + ((.time_open_s_p50 // "–") | tostring)
          + " | " + ((.changes_requested_p50 // "–") | tostring)
          + " | " + ((.commits_after_first_review_p50 // "–") | tostring)
          + " | " + (.sample_size | tostring) + " |" ]
      | join("\n")) end)
  + "\n\n_`* overlap` = low-precision file-overlap signal (directional only, excluded from `rate`). `postCI` = post-merge main-CI failure (objective; not populated by the pure-API MVP — see docs/rework-telemetry.md)._\n"
'
