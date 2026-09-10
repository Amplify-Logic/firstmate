#!/usr/bin/env bash
# Parse the optional fork-owned test registry consumed by bin/fm-test-run.sh.
#
# Registry rows are whitespace-separated and have one of these exact forms:
#   family <family-name> tests/<script>.test.sh
#   covers <repository-path-glob> tests/<script>.test.sh
# Blank lines and lines whose first non-whitespace character is # are ignored.
# A present malformed registry fails closed with an actionable line number.
# A missing library or registry is handled by the guarded hooks in the runner
# and preserves the upstream runner's built-in selection exactly.
#
# Public functions:
#   fork_registry_apply <registry-file>
#   fork_registry_family_for_basename <test-basename>
#   fork_registry_scripts_for_path <repository-relative-path>

FORK_REGISTRY_FAMILY_NAMES=()
FORK_REGISTRY_FAMILY_SCRIPTS=()
FORK_REGISTRY_COVER_GLOBS=()
FORK_REGISTRY_COVER_SCRIPTS=()

fork_registry_error() {
  printf 'fm-fork-test-registry: %s\n' "$*" >&2
}

fork_registry_script_valid() {
  case "$1" in
    tests/*.test.sh)
      case "$1" in
        *'*'*|*'?'*|*'['*) return 1 ;;
      esac
      return 0
      ;;
  esac
  return 1
}

fork_registry_glob_valid() {
  case "$1" in
    ''|/*|./*|../*|*/../*|*/..|*//*|*[$'\r\n']) return 1 ;;
  esac
  return 0
}

fork_registry_apply() { # <registry-file>
  local file=${1:-} line line_no=0 kind value script extra existing
  [ -n "$file" ] || { fork_registry_error 'registry path is required'; return 2; }
  [ -r "$file" ] || { fork_registry_error "registry is not readable: $file"; return 2; }

  FORK_REGISTRY_FAMILY_NAMES=()
  FORK_REGISTRY_FAMILY_SCRIPTS=()
  FORK_REGISTRY_COVER_GLOBS=()
  FORK_REGISTRY_COVER_SCRIPTS=()

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    read -r kind value script extra <<< "$line"
    case "$kind" in
      \#*) continue ;;
    esac
    if [ -n "${extra:-}" ] || [ -z "${script:-}" ]; then
      fork_registry_error "$file:$line_no: expected exactly three fields"
      return 2
    fi
    fork_registry_script_valid "$script" || {
      fork_registry_error "$file:$line_no: invalid test script: $script"
      return 2
    }
    [ -f "$script" ] || {
      fork_registry_error "$file:$line_no: test script does not exist: $script"
      return 2
    }
    case "$kind" in
      family)
        [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
          fork_registry_error "$file:$line_no: invalid family name: $value"
          return 2
        }
        for existing in "${FORK_REGISTRY_FAMILY_SCRIPTS[@]+"${FORK_REGISTRY_FAMILY_SCRIPTS[@]}"}"; do
          [ "$existing" != "$script" ] || {
            fork_registry_error "$file:$line_no: duplicate family owner for $script"
            return 2
          }
        done
        FORK_REGISTRY_FAMILY_NAMES+=("$value")
        FORK_REGISTRY_FAMILY_SCRIPTS+=("$script")
        ;;
      covers)
        fork_registry_glob_valid "$value" || {
          fork_registry_error "$file:$line_no: unsafe repository path glob: $value"
          return 2
        }
        FORK_REGISTRY_COVER_GLOBS+=("$value")
        FORK_REGISTRY_COVER_SCRIPTS+=("$script")
        ;;
      *)
        fork_registry_error "$file:$line_no: unknown row type: $kind"
        return 2
        ;;
    esac
  done < "$file"
}

fork_registry_family_for_basename() { # <test-basename>
  local want=${1:-} index=0 script
  for script in "${FORK_REGISTRY_FAMILY_SCRIPTS[@]+"${FORK_REGISTRY_FAMILY_SCRIPTS[@]}"}"; do
    if [ "${script##*/}" = "$want" ]; then
      printf '%s\n' "${FORK_REGISTRY_FAMILY_NAMES[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

fork_registry_scripts_for_path() { # <repository-relative-path>
  local path=${1:-} index=0 pattern matched=1 script
  for pattern in "${FORK_REGISTRY_COVER_GLOBS[@]+"${FORK_REGISTRY_COVER_GLOBS[@]}"}"; do
    # Registry cover values are intentionally expanded as shell globs.
    # shellcheck disable=SC2254
    case "$path" in
      $pattern)
        script=${FORK_REGISTRY_COVER_SCRIPTS[$index]}
        printf '__script__:%s\n' "${script##*/}"
        matched=0
        ;;
    esac
    index=$((index + 1))
  done
  return "$matched"
}
