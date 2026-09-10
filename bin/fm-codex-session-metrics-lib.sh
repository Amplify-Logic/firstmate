#!/usr/bin/env bash
# Supply the Codex/Astra companion row with real context and provider-quota
# metrics for the EXACT primary session the companion is following.
#
# Sourced by bin/fm-status-bar.sh. The field, threshold, placeholder, and
# provenance contract lives in docs/status-bar.md; this file owns the mechanics.
#
# Public entry point:
#   fm_codex_session_metrics <pane> <backend> <herdr-session> <state-dir> <model>
#     -> "<context-used>\t<quota-used>\t<quota-window>"
#
# Every field is "--" when it cannot be established truthfully. A missing,
# malformed, stale, expired, or unattributable reading is always "--", never 0.
#
# Two metrics, two DIFFERENT owners, deliberately not interchangeable.
#
# Context is this thread's own occupancy of the model context window, so it must
# come from the exact session the companion follows. The followed pane resolves
# to its foreground Codex process, that process is asked which rollout file it
# currently holds OPEN, and only that file is read. Codex holds exactly one
# rollout open per thread, so the open descriptor is the process's own statement
# of which thread it is running. Nothing here picks the newest file in the
# sessions tree: a sibling Codex session - another primary, a worker, the
# desktop app - owns a different descriptor and can never be borrowed. No Codex
# process behind the pane, no rollout, or MORE than one rollout is a refusal.
#
# Provider quota is an ACCOUNT-level allowance and is not this thread's
# consumption, so it is never derived from thread totals. It comes from
# quota-axi, which already owns provider and account resolution, read strictly
# read-only. The row reports the account's own binding window with that window
# named, so the figure can never imply a scope it does not have.
#
# The rollout's own rate_limits block is a THIRD thing and is the trap this
# code exists to avoid. It is stamped with a limit identity - limit_id and
# limit_name - which is frequently NOT the running model's. A gpt-6-astra
# primary was measured reporting limit_id=codex_bengalfox
# (GPT-5.3-Codex-Spark) at 0% used, while the account's actual binding weekly
# window sat at 54% used. Reporting that 0% as the primary's quota is a
# misattribution that reads as "plenty of headroom" when there is not. So the
# rollout's rate_limits are used ONLY when their stamped identity positively
# matches the running model, and are otherwise discarded rather than
# reinterpreted. An identity that cannot be matched is not a fallback: quota
# then comes from the account owner or stays unavailable.
#
# Only metric metadata is read: the last token-count event's token totals,
# context window, and rate-limit identity and windows. Conversation content in
# the rollout is never parsed, printed, or cached.
#
# Cost control: the pane/process/descriptor resolution and rollout read are
# cached for FM_CODEX_METRICS_TTL seconds (default 15). The quota-axi read is
# a subprocess, so it has its own longer FM_CODEX_QUOTA_TTL (default 120) and a
# bounded wait, and it is never run on a per-refresh path. A one-second
# companion refresh therefore performs no subprocess work on most ticks. No
# credential is read, no credential refresh is delegated, and no token value is
# ever printed.
#
# Test seams:
#   FM_CODEX_METRICS_ROLLOUT   use this rollout path instead of resolving one
#   FM_CODEX_METRICS_TTL       rollout cache lifetime in seconds
#   FM_CODEX_QUOTA_TTL         provider-quota cache lifetime in seconds
#   FM_CODEX_QUOTA_JSON        read provider quota from this file, not quota-axi
#   FM_CODEX_QUOTA_DISABLE     set to 1 to skip the provider-quota source
#   FM_CODEX_METRICS_NOW       override the current epoch
#   FM_CODEX_METRICS_NO_CACHE  set to 1 to bypass both caches

# _fm_codex_now: current epoch, or failure when it cannot be read.
_fm_codex_now() {
  local now=${FM_CODEX_METRICS_NOW:-}
  [ -n "$now" ] || now=$(date +%s 2>/dev/null)
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$now"
}

# _fm_codex_ttl: a non-negative integer TTL, or the supplied default.
_fm_codex_ttl() {  # <value> <default>
  local value=$1 fallback=$2
  case "$value" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$value" ;;
  esac
}

# _fm_codex_cache_key: a filesystem-safe token for a cache file name.
_fm_codex_cache_key() {  # <value>
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# _fm_codex_cache_read: a cached payload that is still inside its TTL.
_fm_codex_cache_read() {  # <cache-file> <now> <ttl>
  local cache=$1 now=$2 ttl=$3 modified age raw
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 1
  [ -f "$cache" ] || return 1
  modified=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null)
  case "$modified" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - modified))
  [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] || return 1
  raw=$(cat "$cache" 2>/dev/null) || return 1
  printf '%s' "$raw"
}

# _fm_codex_cache_write: best effort. A state directory that cannot be written
# costs freshness, never a render.
_fm_codex_cache_write() {  # <cache-file> <payload>
  [ "${FM_CODEX_METRICS_NO_CACHE:-}" != 1 ] || return 0
  printf '%s' "$2" > "$1.$$" 2>/dev/null \
    && mv -f "$1.$$" "$1" 2>/dev/null \
    || rm -f "$1.$$" 2>/dev/null || true
  return 0
}

# _fm_codex_normalize_identity: lowercase alphanumerics only, so a model name
# and a provider limit label can be compared without punctuation or case
# defeating the match.
_fm_codex_normalize_identity() {  # <value>
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9'
}

# _fm_codex_identity_matches: whether a rate-limit identity provably belongs to
# the running model. This is a POSITIVE match rule: anything it cannot confirm
# is rejected, because the cost of a wrong match is reporting another model's
# headroom as this primary's. The normalized model must be long enough that a
# substring hit means something.
_fm_codex_identity_matches() {  # <model> <limit-id> <limit-name>
  local model limit_id limit_name
  model=$(_fm_codex_normalize_identity "$1")
  limit_id=$(_fm_codex_normalize_identity "$2")
  limit_name=$(_fm_codex_normalize_identity "$3")
  [ -n "$model" ] || return 1
  [ "${#model}" -ge 4 ] || return 1
  [ "$limit_name" = "$model" ] && return 0
  [ "$limit_id" = "$model" ] && return 0
  case "$limit_id" in
    *"$model"*) return 0 ;;
  esac
  case "$limit_name" in
    *"$model"*) return 0 ;;
  esac
  return 1
}

# _fm_codex_pane_pids: every foreground Codex process id behind the followed
# pane, one per line. Both providers are asked about the pane the companion was
# given, so an answer about a different pane yields nothing rather than a guess.
_fm_codex_pane_pids() {  # <pane> <backend> <herdr-session>
  local pane=$1 backend=$2 session=$3 shell_pid child
  case "$backend" in
    herdr)
      command -v herdr >/dev/null 2>&1 || return 0
      herdr --session "$session" pane process-info --pane "$pane" 2>/dev/null \
        | jq -r '
            .result.process_info.foreground_processes[]?
            | select((.name // "") == "codex" or (.argv0 // "") == "codex")
            | .pid
          ' 2>/dev/null
      ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || return 0
      # tmux reports the pane's shell, so Codex is a descendant of it.
      shell_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || return 0
      case "$shell_pid" in
        ''|*[!0-9]*) return 0 ;;
      esac
      printf '%s\n' "$shell_pid"
      for child in $(pgrep -P "$shell_pid" 2>/dev/null); do
        printf '%s\n' "$child"
        pgrep -P "$child" 2>/dev/null || true
      done
      ;;
  esac
}

# _fm_codex_rollout_for_pids: the single rollout file those processes hold open.
# Zero matches and more than one match are both refusals: there is no safe way
# to choose, and choosing wrongly would report another session's context.
_fm_codex_rollout_for_pids() {  # <pid>...
  local pids paths count
  pids=$(printf '%s,' "$@")
  pids=${pids%,}
  [ -n "$pids" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  paths=$(lsof -p "$pids" -Fn 2>/dev/null \
    | sed -n 's|^n\(.*/sessions/.*/rollout-.*\.jsonl\)$|\1|p' \
    | sort -u)
  [ -n "$paths" ] || return 1
  count=$(printf '%s\n' "$paths" | grep -c .)
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$paths"
}

# _fm_codex_resolve_rollout: the rollout bound to the followed pane.
_fm_codex_resolve_rollout() {  # <pane> <backend> <herdr-session>
  local forced=${FM_CODEX_METRICS_ROLLOUT:-} pids
  if [ -n "$forced" ]; then
    [ -f "$forced" ] || return 1
    printf '%s' "$forced"
    return 0
  fi
  pids=$(_fm_codex_pane_pids "$1" "$2" "$3")
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC2086 # Deliberate splitting: one argument per pid.
  _fm_codex_rollout_for_pids $pids
}

# _fm_codex_window_label: a short, explicit token for a rate-limit window.
# The label is derived from what the source actually reported and is never
# assumed: an unrecognized window yields no label, which makes the whole quota
# reading unavailable rather than ambiguously scoped.
_fm_codex_window_label_from_minutes() {  # <window-minutes>
  local minutes=$1
  case "$minutes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$minutes" -gt 0 ] || return 1
  case "$minutes" in
    300) printf '5h' ;;
    1440) printf '24h' ;;
    10080) printf 'wk' ;;
    *)
      if [ $((minutes % 10080)) -eq 0 ]; then
        printf '%dwk' $((minutes / 10080))
      elif [ $((minutes % 1440)) -eq 0 ]; then
        printf '%dd' $((minutes / 1440))
      elif [ $((minutes % 60)) -eq 0 ]; then
        printf '%dh' $((minutes / 60))
      else
        printf '%dm' "$minutes"
      fi
      ;;
  esac
}

# _fm_codex_window_label_from_id: the same for a quota-axi window identifier.
_fm_codex_window_label_from_id() {  # <window-id>
  case "$1" in
    ''|null) return 1 ;;
    five_hour|five-hour|5h|*:5h) printf '5h' ;;
    daily|*:24h|*:1d) printf '24h' ;;
    weekly|*:7d|*:weekly) printf 'wk' ;;
    monthly|*:30d) printf 'mo' ;;
    annual|yearly|*:1y) printf 'yr' ;;
    *) return 1 ;;
  esac
}

# _fm_codex_read_rollout: context, plus a rate-limit reading ONLY when its
# stamped identity provably belongs to the running model.
#
# Context is the share of the model context window this thread currently
# occupies, from the same two numbers Codex's own `context-used` item is built
# from: the last turn's prompt size and the window Codex itself reported for the
# session. The window is read from the session rather than a model catalog, so
# no capacity is assumed anywhere. Compaction needs no special handling: a
# compacted thread's next event reports the smaller post-compaction prompt.
#
# A window whose reset time has already passed is dropped, because its used
# share describes an expired window and is no longer true of the current one.
_fm_codex_read_rollout() {  # <rollout> <now> <model>
  local rollout=$1 now=$2 model=$3 tail_bytes event
  local ctx limit_id limit_name parsed
  tail_bytes=$(_fm_codex_ttl "${FM_CODEX_METRICS_TAIL_BYTES:-}" 262144)
  # Only the newest token-count event is needed, so read a bounded tail rather
  # than a rollout that grows without limit.
  event=$(tail -c "$tail_bytes" "$rollout" 2>/dev/null \
    | grep '"token_count"' \
    | tail -1)
  [ -n "$event" ] || return 1

  # Identity is extracted first and matched in shell, so the decision to trust
  # or discard the rate-limit block is made in one auditable place.
  IFS=$'\t' read -r limit_id limit_name <<EOF
$(printf '%s' "$event" | jq -r '
  (.payload.rate_limits // {})
  | [((.limit_id // "") | tostring), ((.limit_name // "") | tostring)]
  | @tsv
' 2>/dev/null)
EOF

  local trust_limits=0
  if _fm_codex_identity_matches "$model" "$limit_id" "$limit_name"; then
    trust_limits=1
  fi

  parsed=$(printf '%s' "$event" | jq -r \
    --argjson now "$now" \
    --argjson trust "$trust_limits" '
    def num(v): if (v | type) == "number" then v else null end;
    def pick(w):
      if (w | type) != "object" then null
      else
        (num(w.used_percent)) as $u
        | (num(w.window_minutes)) as $m
        | (num(w.resets_at)) as $r
        | if $u == null or $m == null then null
          elif $r != null and $r <= $now then null
          else {used: ($u | floor), minutes: ($m | floor)}
          end
      end;
    (.payload // {}) as $p
    | ($p.info // {}) as $i
    | (num($i.model_context_window)) as $win
    | (num($i.last_token_usage.input_tokens)) as $tok
    | (if $win == null or $win <= 0 or $tok == null or $tok < 0 then "--"
       else (100 * $tok / $win | floor | if . > 100 then 100 else . end)
       end) as $ctx
    | (if $trust == 1
       then (($p.rate_limits // {}) as $rl | (pick($rl.primary) // pick($rl.secondary)))
       else null
       end) as $q
    | [$ctx,
       (if $q == null then "--" else ($q.used | if . > 100 then 100 else . end) end),
       (if $q == null then "" else ($q.minutes | tostring) end)]
    | @tsv
  ' 2>/dev/null)
  [ -n "$parsed" ] || return 1
  printf '%s' "$parsed"
}

# _fm_codex_quota_axi_json: quota-axi's codex report, read strictly read-only
# and under a bounded wait so a slow provider read can never wedge the row.
# --no-credential-refresh is mandatory here: it keeps the read from delegating
# an expired session's renewal to the vendor CLI, which is what would otherwise
# surface a login prompt behind a status bar.
_fm_codex_quota_axi_json() {
  local override=${FM_CODEX_QUOTA_JSON:-} out pid waited limit
  if [ -n "$override" ]; then
    [ -f "$override" ] || return 1
    cat "$override" 2>/dev/null
    return 0
  fi
  command -v quota-axi >/dev/null 2>&1 || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/fm-codex-quota.XXXXXX") || return 1
  quota-axi --provider codex --json --no-credential-refresh > "$out" 2>/dev/null &
  pid=$!
  waited=0
  limit=$(_fm_codex_ttl "${FM_CODEX_QUOTA_WAIT:-}" 10)
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  if [ -s "$out" ]; then
    cat "$out" 2>/dev/null
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

# _fm_codex_provider_quota: the ACCOUNT's binding allowance and the window that
# binds it, as "<used>\t<window-label>".
#
# The all_models scope is the right one for a Codex primary: Codex reports a
# single account-wide availability scope, so an Astra primary draws on the
# ordinary Codex windows rather than an allowance of its own. quota-axi's
# effective availability already resolves which window binds, so the row does
# not re-derive it.
#
# Everything about this reading must be positively known or it is unavailable:
# a stale report, an unknown semantics status, an unknown scope status, a
# non-numeric percentage, or a binding window whose length cannot be named. The
# limiting window must be exactly one, because a figure bounded by two
# different windows at once cannot be labelled with either without implying a
# scope it does not have.
_fm_codex_provider_quota() {
  local json remaining window_id label count
  [ "${FM_CODEX_QUOTA_DISABLE:-}" != 1 ] || return 1
  json=$(_fm_codex_quota_axi_json) || return 1
  [ -n "$json" ] || return 1

  IFS=$'\t' read -r remaining count window_id <<EOF
$(printf '%s' "$json" | jq -r '
  def num(v): if (v | type) == "number" then v else null end;
  (.providers // [] | map(select(.provider == "codex")) | first) as $p
  | if $p == null then ["--", 0, ""]
    elif ($p.state.stale == true) then ["--", 0, ""]
    elif (($p.quotaSemantics.status // "") != "known") then ["--", 0, ""]
    else
      (($p.quotaSemantics.effectiveAvailability // [])
        | map(select(.scope == "all_models")) | first) as $s
      | if $s == null or (($s.status // "") != "known") then ["--", 0, ""]
        else
          (num($s.effectivePercentRemaining)) as $r
          | (($s.limitingWindowIds // [])) as $w
          | [ (if $r == null then "--" else ($r | floor) end),
              ($w | length),
              ($w | first // "" | tostring) ]
        end
    end
  | @tsv
' 2>/dev/null)
EOF

  case "$remaining" in
    ''|--|*[!0-9]*) return 1 ;;
  esac
  [ "$remaining" -le 100 ] || return 1
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$count" -eq 1 ] || return 1
  label=$(_fm_codex_window_label_from_id "$window_id") || return 1
  [ -n "$label" ] || return 1
  # quota-axi reports REMAINING; the canonical row reports USED.
  printf '%s\t%s' "$((100 - remaining))" "$label"
}

# fm_codex_session_metrics: the public entry point.
# Always succeeds: every failure mode renders as the "--" placeholders the row
# already displays dimly, so a broken reading can never be mistaken for a real
# zero.
fm_codex_session_metrics() {  # <pane> <backend> <herdr-session> <state-dir> <model>
  local pane=$1 backend=$2 session=$3 state=$4 model=${5:-}
  local now key rollout_cache quota_cache ttl quota_ttl raw cached
  local ctx quota minutes label quota_raw rollout

  now=$(_fm_codex_now) || {
    printf '%s\t%s\t' -- --
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\t%s\t' -- --
    return 0
  }

  ttl=$(_fm_codex_ttl "${FM_CODEX_METRICS_TTL:-}" 15)
  quota_ttl=$(_fm_codex_ttl "${FM_CODEX_QUOTA_TTL:-}" 120)
  # Caches are keyed by the followed pane, so two companions in one home never
  # read each other's reading.
  key=$(_fm_codex_cache_key "$pane")
  rollout_cache="$state/.status-codex-metrics.$key"
  quota_cache="$state/.status-codex-quota.$key"

  ctx=--
  quota=--
  label=
  cached=$(_fm_codex_cache_read "$rollout_cache" "$now" "$ttl") || cached=
  if [ -n "$cached" ]; then
    IFS=$'\t' read -r ctx quota minutes <<EOF
$cached
EOF
  else
    rollout=$(_fm_codex_resolve_rollout "$pane" "$backend" "$session") || rollout=
    raw=
    [ -z "$rollout" ] || raw=$(_fm_codex_read_rollout "$rollout" "$now" "$model") || raw=
    IFS=$'\t' read -r ctx quota minutes <<EOF
$raw
EOF
    _fm_codex_cache_write "$rollout_cache" "$ctx"$'\t'"$quota"$'\t'"$minutes"
  fi

  case "$ctx" in
    ''|*[!0-9]*) ctx=-- ;;
  esac
  case "$quota" in
    ''|*[!0-9]*) quota=-- ;;
  esac
  if [ "$quota" != -- ]; then
    label=$(_fm_codex_window_label_from_minutes "$minutes") || label=
    # A figure whose window cannot be named is not reportable: the row would
    # have to imply a window it does not know.
    [ -n "$label" ] || quota=--
  fi

  # The model-matched session rate limit is preferred when it exists, because it
  # is the window the running model actually consumes. Otherwise the account
  # owner supplies the binding allowance.
  if [ "$quota" = -- ]; then
    quota_raw=$(_fm_codex_cache_read "$quota_cache" "$now" "$quota_ttl") || quota_raw=
    if [ -z "$quota_raw" ]; then
      quota_raw=$(_fm_codex_provider_quota) || quota_raw=$'--\t'
      _fm_codex_cache_write "$quota_cache" "$quota_raw"
    fi
    IFS=$'\t' read -r quota label <<EOF
$quota_raw
EOF
    case "$quota" in
      ''|*[!0-9]*) quota=--; label= ;;
    esac
    [ "$quota" = -- ] || [ -n "$label" ] || quota=--
  fi

  printf '%s\t%s\t%s' "$ctx" "$quota" "$label"
}
