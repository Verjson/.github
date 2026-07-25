#!/usr/bin/env bash
# Pure aggregator for the rework reconciler (issue #33). Reads an enriched
# per-PR array (from rework-classify.sh) on stdin and emits one
# ReworkTelemetryPayload-shaped object per (change_category, ai_authored) bucket
# — the schema shipped upstream in verjson-observability#49, so the future OTLP
# emit path is a drop-in. Pure; unit-tested from fixtures
# (scripts/ci-telemetry/rework-aggregate.test.sh).
#
# The headline rework_rate counts a PR once if it carries ANY high/medium/
# objective signal (revert | explicit_fix_ref | fix_same_area | post_merge_ci_fail).
# Low-precision file_overlap is reported separately and deliberately EXCLUDED
# from the rate (ticket guardrail: directional-only, never in the headline).
set -euo pipefail

repository="${1:?usage: rework-aggregate.sh <repository> <window_start> <window_end> <window_days>}"
window_start="${2:?window_start required}"
window_end="${3:?window_end required}"
window_days="${4:?window_days required}"

jq \
  --arg repository "$repository" \
  --arg ws "$window_start" \
  --arg we "$window_end" \
  --argjson wd "$window_days" '
  def median:
    (map(select(. != null)) | sort) as $s
    | if   ($s | length) == 0        then null
      elif ($s | length) % 2 == 1    then $s[(($s | length) - 1) / 2]
      else (($s[($s | length) / 2 - 1] + $s[($s | length) / 2]) / 2) end;

  def round4: (. * 10000 | round) / 10000;

  group_by([.change_category, .ai_authored])
  | map(
        (.[0].change_category) as $cat
      | (.[0].ai_authored)     as $ai
      | length                 as $merged
      | (map(select(.rework_signal == "revert"))           | length) as $revert
      | (map(select(.rework_signal == "explicit_fix_ref")) | length) as $fixref
      | (map(select(.rework_signal == "fix_same_area"))    | length) as $fixarea
      | (map(select(.post_merge_ci_fail == true))          | length) as $postci
      | (map(select(.file_overlap_only == true))           | length) as $overlap
      | (map(select((.rework_signal != null) or (.post_merge_ci_fail == true))) | length) as $rework
      | {
          repository: $repository,
          window_start: $ws,
          window_end: $we,
          window_days: $wd,
          change_category: $cat,
          ai_authored: $ai,
          merged_count: $merged,
          rework_count: $rework,
          rework_rate: (if $merged > 0 then ($rework / $merged | round4) else 0 end),
          rework_by_signal: {
            revert: $revert,
            explicit_fix_ref: $fixref,
            fix_same_area: $fixarea,
            post_merge_ci_fail: $postci
          },
          file_overlap_only: $overlap,
          review_rounds_p50:              (map(.review_rounds) | median),
          time_open_s_p50:                (map(.time_open_s) | median),
          changes_requested_p50:          (map(.changes_requested) | median),
          commits_after_first_review_p50: (map(.commits_after_first_review) | median),
          sample_size: $merged
        }
    )
'
