#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# A squash merge supplies its own commit body. GitHub composes the default
# squash body from every commit in the PR and appends a hoisted
# Co-authored-by block, so an agent trailer removed from the branch tip comes
# back at merge time unless the body is supplied explicitly. This script reads
# the forge's own merge-box body, drops agent co-author and Claude-Session
# trailers from it, and passes the result back as --body-file; human
# co-authors are preserved and every other line is unchanged. The body is read
# with gh rather than gh-axi because gh returns the message verbatim, while
# gh-axi's api wrapper re-renders and may truncate it, and a commit message
# must land byte for byte. A body the caller supplies is sanitized the same
# way. Merge and rebase merges compose no message here.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# Echo the merge method the caller named, for a caller that named one.
caller_merge_method() {
  local arg awaiting_value=0
  for arg in "$@"; do
    if [ "$awaiting_value" -eq 1 ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      --squash) printf 'squash\n'; return 0 ;;
      --merge) printf 'merge\n'; return 0 ;;
      --rebase) printf 'rebase\n'; return 0 ;;
      --method=*) printf '%s\n' "${arg#--method=}"; return 0 ;;
      --method) awaiting_value=1 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Filter a commit message on stdin: drop Claude-Session trailers and every
# Co-authored-by trailer whose identity names an agent, then drop the
# separator and blank lines a fully stripped trailer block leaves behind.
# A co-author is an agent when any word of its name or address is one of the
# agent words, which covers agent addresses at noreply.anthropic.com and at
# users.noreply.github.com without touching a human who shares that domain.
strip_agent_trailers() {
  awk '
    BEGIN {
      split("claude codex cursor grok kimi opus fable gpt openai anthropic", agent_words, " ")
    }
    function is_agent(value,   words, i) {
      words = " " tolower(value) " "
      gsub(/[^a-z0-9]+/, " ", words)
      for (i in agent_words) {
        if (index(words, " " agent_words[i] " ") > 0) return 1
      }
      return 0
    }
    {
      lowered = tolower($0)
      if (lowered ~ /^claude-session:/) { dropped = 1; next }
      if (lowered ~ /^co-authored-by:/ && is_agent(substr($0, index($0, ":") + 1))) {
        dropped = 1
        next
      }
      # A trailer removed from the middle of the message leaves the blank line
      # that separated it from the next block; keep one blank, not two.
      if (dropped && $0 ~ /^[[:space:]]*$/ && count > 0 && kept[count] ~ /^[[:space:]]*$/) {
        dropped = 0
        next
      }
      dropped = 0
      kept[++count] = $0
    }
    END {
      while (count > 0 && kept[count] ~ /^[[:space:]]*$/) count--
      if (count > 0 && kept[count] ~ /^-{3,}[[:space:]]*$/) count--
      while (count > 0 && kept[count] ~ /^[[:space:]]*$/) count--
      for (i = 1; i <= count; i++) print kept[i]
    }
  '
}

# The forge's own merge-box body for a squash merge, exactly as GitHub would
# use it when this script supplies none.
default_squash_body() {
  # shellcheck disable=SC2016  # GraphQL variables are literal, not shell expansions.
  gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){viewerMergeBodyText(mergeType:SQUASH)}}}' \
    -F owner="$PR_OWNER" -F repo="$PR_REPO" -F number="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.viewerMergeBodyText'
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if caller_has_merge_method "$@"; then
  # A caller-named method with no value stays empty, composes no message, and
  # is left for gh-axi to refuse.
  METHOD=$(caller_merge_method "$@" || true)
else
  METHOD=squash
  merge_args=(--squash)
fi

BODY_RAW=
BODY_CLEAN=
cleanup_body() {
  [ -z "$BODY_RAW" ] || rm -f -- "$BODY_RAW"
  [ -z "$BODY_CLEAN" ] || rm -f -- "$BODY_CLEAN"
}
trap cleanup_body EXIT

forward_args=("$@")
body_args=()
if [ "$METHOD" = squash ]; then
  # A caller-supplied body replaces the forge default as the source, and its
  # flags leave the forwarded arguments so only the sanitized copy is sent.
  caller_body=
  caller_body_file=
  caller_body_set=0
  awaiting=
  forward_args=()
  for arg in "$@"; do
    case "$awaiting" in
      body) caller_body=$arg; awaiting=; continue ;;
      body-file) caller_body_file=$arg; awaiting=; continue ;;
    esac
    case "$arg" in
      --body) awaiting=body; caller_body_set=1; continue ;;
      --body=*) caller_body=${arg#--body=}; caller_body_set=1; continue ;;
      --body-file) awaiting=body-file; caller_body_set=1; continue ;;
      --body-file=*) caller_body_file=${arg#--body-file=}; caller_body_set=1; continue ;;
    esac
    forward_args+=("$arg")
  done

  BODY_RAW=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-body.XXXXXX") || exit 1
  BODY_CLEAN=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-body.XXXXXX") || exit 1
  if [ "$caller_body_set" -eq 1 ]; then
    if [ -n "$caller_body_file" ]; then
      cat -- "$caller_body_file" > "$BODY_RAW" || {
        echo "error: could not read the supplied merge body file" >&2
        exit 1
      }
    else
      printf '%s\n' "$caller_body" > "$BODY_RAW" || exit 1
    fi
  elif ! command -v gh >/dev/null 2>&1; then
    echo "error: composing a squash commit message requires gh on PATH" >&2
    exit 1
  elif ! default_squash_body > "$BODY_RAW"; then
    echo "error: could not read the pull request's squash commit message" >&2
    exit 1
  fi
  strip_agent_trailers < "$BODY_RAW" > "$BODY_CLEAN" || exit 1
  body_args=(--body-file "$BODY_CLEAN")
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
  "${merge_args[@]+"${merge_args[@]}"}" "${forward_args[@]+"${forward_args[@]}"}" \
  "${body_args[@]+"${body_args[@]}"}"
