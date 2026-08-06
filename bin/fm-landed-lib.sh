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
# that invariant and hid a completion the captain had just watched finish:
# completion dates are day-granularity, so every completion recorded on the same
# day tied, and the tie was broken on `.id`, which is unrelated to recency. A
# just-finished task with an alphabetically-low id therefore lost its place to
# same-day completions that had finished earlier and was the first row the cap
# discarded. That is the defect this rule fixes, and it is the only one: a
# mis-ordering cannot empty a landed list, so an EMPTY landed section has a
# different cause and is not addressed here.
#
# THE RULE
#
# Rank dated rows above undated rows; within the dated set, rank by completion
# date descending, then by recording position within the Done section, earliest
# position first. Three properties make that truthful:
#
#   * DATED EVIDENCE WINS. An undated Done row sorts BELOW every dated row and is
#     never re-dated as "now". An earlier approach dated undated rows as of the
#     snapshot's generation time; that let a hand-edited or manual-backend home
#     full of undated rows displace genuinely dated completions out of a capped
#     list, which is the same trust failure inverted and is worse than an undated
#     row sorting last. Undated rows tie-break among themselves by recording
#     position, newest-first, exactly as dated rows do.
#   * `order` is the row's 1-based position in the parsed backlog (assigned by
#     fm-fleet-snapshot.sh's backlog_json). The Done section is maintained
#     newest-first, so a LOWER order is MORE recent, which is why the key negates
#     it. That depends on Done actually being written newest-first: `tasks-axi
#     done` PREPENDS each completed row (verified against tasks-axi 0.2.3), and
#     bin/fm-teardown.sh's manual-backlog instruction tells the captain to insert
#     the finished row at the TOP of Done together with its completion date for
#     the same reason.
#   * Equal keys keep their INPUT order, because the sort is a stable ascending
#     sort of the reversed input, re-reversed. That is what lets a caller publish
#     rows in this order and re-sort them later without `order`: the fleet layer
#     strips the internal `order` field from the rows it publishes, and each
#     home's already-correct newest-first order survives every later re-sort.
#
# A row that carries no `order` is treated as order 0, which ranks it AHEAD of
# every row with a positive order inside the same date group; it does not keep its
# input position relative to those rows. Rows that all lack `order` tie, so they
# do keep their input order relative to each other. A consumer that needs
# position-accurate ranking across rows must project `order` onto them.
#
# WHAT THIS GUARANTEES, AND WHAT IT DOES NOT
#
# With this ordering, the newest DATED completion in a home is always at index 0
# of that home's group, so the per-home cap and the round-robin merge can never
# discard it. tests/fm-landed-completion-truth.test.sh pins that property. The
# guarantee is scoped to a completion recorded as a structured `- [x] <id> - <rest>`
# Done row carrying its completion date: an undated row ranks below every dated
# one and can rotate out under the cap, and a completion never recorded into Done
# at all cannot appear at all.

# Emits the jq prelude defining landed_newest_first. Callers interpolate it ahead
# of their own program text, e.g. jq "$(fm_landed_jq_prelude)"'<program>'.
fm_landed_jq_prelude() {
  cat <<'JQ'
def landed_recency_key:
  (.completion.date // "") as $date
  | [(if $date == "" then 0 else 1 end), $date, (0 - (.order // 0))];
def landed_newest_first:
  reverse | sort_by(landed_recency_key) | reverse;
JQ
}
