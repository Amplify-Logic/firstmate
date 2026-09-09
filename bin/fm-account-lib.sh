# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_ACCOUNT_ERROR is an output global for sourcing callers.
# bin/fm-account-lib.sh - named vendor account resolution for primary launches
# and crewmate spawns.
# Usage: . bin/fm-account-lib.sh
#
# One concept for both vendors: a NAMED ACCOUNT, per vendor, backed by its own
# isolated home directory under this Firstmate home's private data dir.
#   claude -> $DATA/accounts/claude/<name>, exported as CLAUDE_CONFIG_DIR
#   codex  -> $DATA/accounts/codex/<name>,  exported as CODEX_HOME
# Home paths are DERIVED from vendor and name, never read from the registry, so
# a registry file can never point a launch at an arbitrary directory.
#
# The registry is local, gitignored config/accounts.json; docs/configuration.md
# owns its schema and bin/fm-bootstrap.sh validates it. An ABSENT registry means
# one thing only: no pinning, every launch uses the ambient vendor home exactly
# as it did before account pinning existed.
#
# Credentials are never copied, linked, or seeded between homes. A fresh account
# home is empty and unauthenticated, and the captain logs into it by hand with
# the command fm_account_login_command prints (data/captain.md Accounts).
#
# Error reporting: a function that refuses sets FM_ACCOUNT_ERROR to the reason
# and returns 1, so each caller can raise it through its own die/refusal prefix
# instead of this library guessing which script it is running inside.
# FM_ACCOUNT_NAME and FM_ACCOUNT_HOME are the matching output globals.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_ERROR=
FM_ACCOUNT_NAME=
FM_ACCOUNT_HOME=

# fm_account_vendors: every vendor with an account concept, in help order.
fm_account_vendors() {
  printf 'claude codex'
}

# fm_account_env_var: the isolation variable a vendor's account home is exported
# as. Both were re-verified on this machine on 2026-09-09 (see the
# harness-adapters skill); an unknown vendor returns 1 rather than guessing.
fm_account_env_var() {  # <vendor>
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR' ;;
    codex) printf 'CODEX_HOME' ;;
    *) return 1 ;;
  esac
}

# fm_account_registry_file: the local registry path for a config dir.
fm_account_registry_file() {  # <config-dir>
  printf '%s/accounts.json' "$1"
}

# fm_account_home: the derived isolated home for one named account.
fm_account_home() {  # <data-dir> <vendor> <name>
  printf '%s/accounts/%s/%s' "$1" "$2" "$3"
}

# fm_account_name_ok: an account name is one path segment of safe characters, so
# it can never escape the derived vendor directory.
fm_account_name_ok() {  # <name>
  case "$1" in
    ''|.|..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    .*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_account_defined_names: the account names the registry defines for a vendor,
# space separated, or nothing at all. Callers use it to name the real options in
# a refusal.
fm_account_defined_names() {  # <registry-file> <vendor>
  local file=$1 vendor=$2
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg v "$vendor" '
    (.[$v]?.accounts? // {}) | keys_unsorted | join(" ")
  ' "$file" 2>/dev/null || true
}

# fm_account_resolve: decide which account a launch runs on.
#
# Sets FM_ACCOUNT_NAME and FM_ACCOUNT_HOME as output globals, both empty when no
# pin applies. No pin applies when the registry is absent, when the vendor has no
# entry, or when the vendor has no default and no account was requested - all of
# which leave the ambient vendor home in charge.
#
# Returns 1 with FM_ACCOUNT_ERROR set when a requested or default account is not
# defined, when a name is unsafe, or when the registry exists but cannot be read.
#
# Output globals rather than stdout on purpose: a caller reading this through
# command substitution would run it in a subshell, where the refusal reason set
# on failure could never reach the caller that has to print it.
fm_account_resolve() {  # <config-dir> <data-dir> <vendor> [<requested-name>]
  local config_dir=$1 data_dir=$2 vendor=$3 requested=${4:-}
  local file names name
  FM_ACCOUNT_ERROR=
  FM_ACCOUNT_NAME=
  FM_ACCOUNT_HOME=
  file=$(fm_account_registry_file "$config_dir")
  if [ ! -f "$file" ]; then
    if [ -n "$requested" ]; then
      FM_ACCOUNT_ERROR="no accounts are defined: $file does not exist, so --account $requested cannot be resolved"
      return 1
    fi
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FM_ACCOUNT_ERROR="$file exists but 'jq' is not on PATH, so the pinned account cannot be resolved"
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    FM_ACCOUNT_ERROR="$file is not valid JSON; fix it or remove it (an absent file means no account pinning)"
    return 1
  fi
  names=$(fm_account_defined_names "$file" "$vendor")
  name=$requested
  if [ -z "$name" ]; then
    name=$(jq -r --arg v "$vendor" '.[$v]?.default? // "" | tostring' "$file" 2>/dev/null || true)
    [ -n "$name" ] || return 0
  fi
  if ! fm_account_name_ok "$name"; then
    FM_ACCOUNT_ERROR="invalid $vendor account name '$name'; use letters, digits, dot, dash, or underscore"
    return 1
  fi
  case " $names " in
    *" $name "*) ;;
    *)
      if [ -n "$names" ]; then
        FM_ACCOUNT_ERROR="unknown $vendor account '$name'; $file defines: $names"
      else
        FM_ACCOUNT_ERROR="unknown $vendor account '$name'; $file defines no $vendor accounts"
      fi
      return 1
      ;;
  esac
  FM_ACCOUNT_NAME=$name
  FM_ACCOUNT_HOME=$(fm_account_home "$data_dir" "$vendor" "$name")
}

# fm_account_login_command: the exact command the captain runs to log one account
# home in. Firstmate never runs it: a login is the captain's hands, and no
# credential is ever copied from another home.
fm_account_login_command() {  # <vendor> <home>
  case "$1" in
    claude) printf "CLAUDE_CONFIG_DIR=%s claude" "$2" ;;
    codex) printf "CODEX_HOME=%s codex login" "$2" ;;
    *) return 1 ;;
  esac
}

# fm_account_logged_out: 0 only when the vendor CLI gives an EXPLICIT logged-out
# reading for that home. An unreadable, timed-out, or unrecognized answer is not
# evidence of a logged-out account and must never refuse a launch that would
# otherwise work - the same rule the Cursor primary login gate follows.
fm_account_logged_out() {  # <vendor> <home> <cli-binary>
  local vendor=$1 home=$2 cli=$3 out
  command -v "$cli" >/dev/null 2>&1 || return 1
  case "$vendor" in
    claude)
      # `claude auth status` prints its JSON on stdout and exits 1 when that home
      # is logged out (verified 2.1.258, 2026-09-09), so the exit status is not
      # the signal - the explicit loggedIn field is.
      out=$(CLAUDE_CONFIG_DIR="$home" fm_run_timeout 10 "$cli" auth status 2>/dev/null) || true
      case "$out" in
        *'"loggedIn": false'*|*'"loggedIn":false'*) return 0 ;;
      esac
      ;;
    codex)
      # `codex login status` writes "Not logged in" to stderr and prints nothing
      # on stdout, so this must read both streams.
      out=$(CODEX_HOME="$home" fm_run_timeout 10 "$cli" login status 2>&1) || true
      case "$out" in
        *'Not logged in'*|*'not logged in'*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# fm_account_create_home: create one empty account home, 0700, and nothing else.
# It never seeds config or credentials from anywhere.
fm_account_create_home() {  # <home>
  local home=$1
  FM_ACCOUNT_ERROR=
  if [ -L "$home" ]; then
    FM_ACCOUNT_ERROR="account home is a symlink; refusing to use it: $home"
    return 1
  fi
  if ! mkdir -p "$home"; then
    FM_ACCOUNT_ERROR="could not create account home: $home"
    return 1
  fi
  chmod 0700 "$home" 2>/dev/null || true
}
