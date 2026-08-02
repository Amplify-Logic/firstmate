#!/usr/bin/env bash
# Shared landed-recency ordering: the single source of truth for how completed
# ("Done") backlog rows are ranked newest-first before any cap is applied.
#
# Sourced by BOTH the canonical snapshot (bin/fm-fleet-snapshot.sh, which ranks
# each secondmate home's own Done roll-up) and the bearings projection
# (bin/fm-bearings-snapshot.sh, which ranks this home's Done and the merged
# cross-home set). Every landed surface caps its list, so the ordering decides
# which rows survive. One copy of the rule keeps the two scripts from drifting
# into disagreeing about which completion is the newest.
#
# WHY THIS IS A CORRECTNESS CONTRACT, NOT A PRESENTATION PREFERENCE
#
# A capped newest-first list is only truthful if the cap drops the OLDEST rows.
# The previous key, `sort_by([(.completion.date // ""), .id]) | reverse`, broke
# that invariant in two ways, and both hid a completion the captain had just
# watched finish:
#
#   1. A Done row with no recorded completion date got the empty string, which
#      sorts BELOW every real date. A completion recorded but not yet dated was
#      therefore ranked as the oldest thing in the fleet and was the first row
#      the cap discarded.
#   2. Completion dates are day-granularity, so every completion recorded today
#      ties. The tie was broken on `.id`, which is unrelated to recency, so a
#      just-finished task with an alphabetically-low id lost its place to
#      same-day completions that had finished earlier.
#
# THE RULE
#
# Rank by completion date descending, then by recording position within the Done
# section, earliest position first. Two inputs make that truthful:
#
#   * An undated Done row is dated as of the snapshot's own generation time
#     rather than treated as infinitely old. Nothing has dated it, so the only
#     moment we can prove it existed is now; ranking it as "just now" is both
#     the honest reading and the safe failure direction, because over-reporting
#     a recent completion is recoverable and hiding one is the trust bug.
#   * `order` is the row's 1-based position in the parsed backlog (assigned by
#     fm-fleet-snapshot.sh's backlog_json). The Done section is maintained
#     newest-first, so a LOWER order is MORE recent, which is why the key
#     negates it: the surrounding `reverse` then leaves order ascending.
#
# Consumers must project `order` onto their landed rows before sorting; a row
# without it falls back to 0 and simply keeps its input position among its ties.
#
# CONSEQUENCE THE TESTS RELY ON
#
# With this ordering, the newest completion in a home is always at index 0 of
# that home's group, so the per-home cap and the round-robin merge can never
# discard it. tests/fm-bearings-completion-truth.test.sh pins that property.

# Emits the jq prelude defining landed_newest_first($now). Callers interpolate it
# ahead of their own program text, e.g. jq "$(fm_landed_jq_prelude)"'<program>'.
# $now is any ISO-8601 instant or YYYY-MM-DD date; only the leading date is used,
# so a caller can pass its existing generation timestamp unchanged.
fm_landed_jq_prelude() {
  cat <<'JQ'
def landed_recency_key($now):
  ((.completion.date // "") | if . == "" then ($now[:10]) else . end) as $date
  | [$date, (0 - (.order // 0))];
def landed_newest_first($now):
  sort_by(landed_recency_key($now)) | reverse;
JQ
}
