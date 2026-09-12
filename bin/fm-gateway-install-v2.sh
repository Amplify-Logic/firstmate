#!/usr/bin/env bash
# fm-gateway-install-v2.sh - installation lifecycle for the action gateway v2.
#
# This script produces the artifacts a privileged installation needs and shows
# exactly what that installation would do. It never performs one, and it never
# performs an uninstall. `apply` is present and always refuses, because creating
# the service principals, writing the root-owned state ancestors, loading the
# launch definitions, and enrolling the approver key are the captain's own step
# at the Mac, not something an agent does on his behalf.
#
# That refusal is the point of the script rather than a limitation of it. Until
# those commands run under the captain's hands, the gateway's own evidence
# boundary says plainly that distinct installed principals, root-owned
# ancestors, Secure Enclave enrollment, signed UI identity, root launch
# definitions, and network isolation are unproven - and no artifact emitted here
# changes that.
#
# Two rules govern every path this script names or emits:
#
#   Fixed and validated   Every privileged path is a literal constant, checked at
#                         startup for being absolute, normalized, and deep enough
#                         that a truncated or emptied constant can never resolve
#                         to /, /var, /usr, or any other shared ancestor.
#   Never recursive       Uninstall does not delete directories. It moves them to
#                         a timestamped quarantine directory after checking that
#                         the target is not a symlink, is contained in its
#                         expected parent, and is owned by the account that
#                         installed it. Deleting the quarantine afterwards is a
#                         separate decision a person makes with the evidence in
#                         front of them.
#
# Commands:
#   preview            Print the complete activation plan: principals, paths,
#                      owners, modes, launch definitions, and the exact
#                      privileged commands, in the order they must run.
#   check              Report what is actually installed right now, honestly.
#                      Exit 0 when every installed path is present, 3 when it is
#                      not. Reads only; changes nothing.
#   artifacts DIR      Write the launch definition and the install, check, and
#                      uninstall scripts into DIR for review. DIR must not exist
#                      or must be empty. Nothing written there is executable and
#                      nothing written there is run.
#   rollback-preview   Print the guarded uninstall script, in the order its steps
#                      must run to leave no privileged remnant.
#   apply              Always refuses. See above.
#
# This script writes only into a DIR the caller names, and runs none of the
# commands it prints.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT

# Every privileged path below is a literal. assert_fixed_path re-checks each one
# at startup, so a constant that is ever emptied or truncated by an edit fails
# the script instead of being interpolated into a command.
readonly STATE_PARENT=/var/db/firstmate
readonly STATE_ROOT=/var/db/firstmate/gateway
readonly SOCKET_PARENT=/var/run/firstmate
readonly SOCKET_ROOT=/var/run/firstmate/gateway
readonly INSTALL_PARENT=/usr/local/libexec
readonly INSTALL_ROOT=/usr/local/libexec/firstmate
readonly QUARANTINE_PARENT=/var/db/firstmate
readonly LAUNCH_DAEMONS=/Library/LaunchDaemons
readonly BROKER_LABEL=ai.firstmate.gateway-v2
readonly BROKER_PLIST=/Library/LaunchDaemons/ai.firstmate.gateway-v2.plist
readonly RUNNER_PLIST=/Library/LaunchDaemons/ai.firstmate.gateway-v2-runner.plist
readonly BROKER_USER=_firstmate_gateway
readonly RUNNER_USER=_firstmate_runner
readonly ROLE_ACCOUNT_HOME=/var/empty

readonly BROKER_PROGRAM=fm-action-gateway-v2.py
readonly SINK_PROGRAM=fm-action-safe-sink-v2.py
readonly RUNNER_PROGRAM=fm-action-runner-v2.py
readonly IMPORTER_PROGRAM=fm-action-artifact-import-v2.py

readonly CONFIRM_FLAG=--i-have-read-every-line

usage() {
  sed -n '2,/^# This script writes only/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-gateway-install-v2: %s\n' "$1" >&2
  exit 1
}

# assert_fixed_path <label> <path> <minimum-depth>
#
# Refuses an empty, relative, unnormalized, or shallow constant. The depth floor
# is what stops a truncated constant from naming a shared ancestor: /usr/local
# has depth 2 and is refused where /usr/local/libexec/firstmate has depth 4.
assert_fixed_path() {
  local label=$1 path=$2 minimum=$3 depth
  [ -n "$path" ] || die "$label is empty"
  case "$path" in
    /*) ;;
    *) die "$label is not an absolute path: $path" ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/.|*/..) die "$label is not a normalized path: $path" ;;
  esac
  depth=$(printf '%s' "${path#/}" | awk -F/ '{print NF}')
  [ "$depth" -ge "$minimum" ] || die "$label is too shallow to be an install target: $path"
}

assert_constants() {
  assert_fixed_path STATE_PARENT "$STATE_PARENT" 3
  assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
  assert_fixed_path SOCKET_PARENT "$SOCKET_PARENT" 3
  assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
  assert_fixed_path INSTALL_PARENT "$INSTALL_PARENT" 3
  assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
  assert_fixed_path QUARANTINE_PARENT "$QUARANTINE_PARENT" 3
  assert_fixed_path LAUNCH_DAEMONS "$LAUNCH_DAEMONS" 2
  assert_fixed_path BROKER_PLIST "$BROKER_PLIST" 3
  assert_fixed_path RUNNER_PLIST "$RUNNER_PLIST" 3
  case "$STATE_ROOT" in "$STATE_PARENT"/?*) ;; *) die "STATE_ROOT is not contained in STATE_PARENT" ;; esac
  case "$SOCKET_ROOT" in "$SOCKET_PARENT"/?*) ;; *) die "SOCKET_ROOT is not contained in SOCKET_PARENT" ;; esac
  case "$INSTALL_ROOT" in "$INSTALL_PARENT"/?*) ;; *) die "INSTALL_ROOT is not contained in INSTALL_PARENT" ;; esac
  case "$BROKER_PLIST" in "$LAUNCH_DAEMONS"/?*) ;; *) die "BROKER_PLIST is not contained in LAUNCH_DAEMONS" ;; esac
  case "$RUNNER_PLIST" in "$LAUNCH_DAEMONS"/?*) ;; *) die "RUNNER_PLIST is not contained in LAUNCH_DAEMONS" ;; esac
}

program_digest() {  # <program>
  local path="$ROOT/bin/$1"
  [ -f "$path" ] || die "missing program: bin/$1"
  /usr/bin/shasum -a 256 "$path" | awk '{print $1}'
}

launch_plist() {  # <label> <user> <program-path> <args...>
  local label=$1 user=$2 program=$3
  shift 3
  local argument
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
  printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '%s\n' '<plist version="1.0">'
  printf '%s\n' '<dict>'
  printf '  <key>Label</key><string>%s</string>\n' "$label"
  printf '%s\n' '  <key>ProgramArguments</key>'
  printf '%s\n' '  <array>'
  printf '    <string>%s</string>\n' /usr/bin/python3
  printf '    <string>%s</string>\n' "$program"
  for argument in "$@"; do
    printf '    <string>%s</string>\n' "$argument"
  done
  printf '%s\n' '  </array>'
  printf '  <key>UserName</key><string>%s</string>\n' "$user"
  printf '%s\n' '  <key>RunAtLoad</key><true/>'
  printf '%s\n' '  <key>KeepAlive</key><true/>'
  printf '%s\n' '  <key>ProcessType</key><string>Background</string>'
  printf '%s\n' '  <key>EnvironmentVariables</key>'
  printf '%s\n' '  <dict/>'
  printf '  <key>WorkingDirectory</key><string>%s</string>\n' /
  printf '%s\n' '  <key>SoftResourceLimits</key>'
  printf '%s\n' '  <dict><key>NumberOfFiles</key><integer>256</integer></dict>'
  printf '%s\n' '</dict>'
  printf '%s\n' '</plist>'
}

# The guard preamble both emitted scripts carry. They are run standalone by a
# person with sudo, so each one has to validate its own paths rather than trust
# that this authoring script validated them.
emit_guard_preamble() {
  cat <<'GUARD'
set -eu

if [ "${1:-}" != "--i-have-read-every-line" ]; then
  printf 'refusing to run without %s.\n' "--i-have-read-every-line" >&2
  printf 'Read every line of this file first. It runs privileged commands.\n' >&2
  exit 3
fi

# assert_fixed_path <label> <path> <minimum-depth>: refuse an empty, relative,
# unnormalized, or shallow path before it is ever handed to a command.
assert_fixed_path() {
  label=$1; path=$2; minimum=$3
  [ -n "$path" ] || { printf 'refusing: %s is empty\n' "$label" >&2; exit 1; }
  case "$path" in
    /*) ;;
    *) printf 'refusing: %s is not absolute: %s\n' "$label" "$path" >&2; exit 1 ;;
  esac
  case "$path" in
    *//*|*/./*|*/../*|*/.|*/..)
      printf 'refusing: %s is not normalized: %s\n' "$label" "$path" >&2; exit 1 ;;
  esac
  depth=$(printf '%s' "${path#/}" | awk -F/ '{print NF}')
  [ "$depth" -ge "$minimum" ] || {
    printf 'refusing: %s is too shallow: %s\n' "$label" "$path" >&2; exit 1; }
}

# assert_contained <child> <parent>: refuse a path that is not strictly inside
# the parent it is supposed to live in.
assert_contained() {
  case "$1" in
    "$2"/?*) ;;
    *) printf 'refusing: %s is not contained in %s\n' "$1" "$2" >&2; exit 1 ;;
  esac
}

# assert_not_symlink <path>: a symlinked install target redirects every later
# write, so it is refused rather than followed.
assert_not_symlink() {
  [ ! -L "$1" ] || { printf 'refusing: %s is a symlink\n' "$1" >&2; exit 1; }
}

# assert_owner <path> <expected-owner>: refuse to touch a path some other owner
# put there under a name this install expects.
assert_owner() {
  observed=$(/usr/bin/stat -f '%Su' "$1" 2>/dev/null || printf 'unknown')
  [ "$observed" = "$2" ] || {
    printf 'refusing: %s is owned by %s, expected %s\n' "$1" "$observed" "$2" >&2
    exit 1; }
}
GUARD
}

emit_install_script() {
  emit_guard_preamble
  cat <<CMD

assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
assert_contained "$INSTALL_ROOT" "$INSTALL_PARENT"
assert_contained "$STATE_ROOT" "$STATE_PARENT"
assert_contained "$SOCKET_ROOT" "$SOCKET_PARENT"

# 1. Create the two service principals. They are distinct accounts, not one
#    account with two names: the whole privilege separation rests on the runner
#    being unable to read the broker's state directory.
sudo sysadminctl -addUser $BROKER_USER -home $ROLE_ACCOUNT_HOME -shell /usr/bin/false -roleAccount
sudo sysadminctl -addUser $RUNNER_USER -home $ROLE_ACCOUNT_HOME -shell /usr/bin/false -roleAccount

# 2. Install the programs root-owned and not writable by either service account.
sudo /usr/bin/install -d -o root -g wheel -m 0755 $INSTALL_ROOT
sudo /usr/bin/install -o root -g wheel -m 0755 $ROOT/bin/$BROKER_PROGRAM $INSTALL_ROOT/$BROKER_PROGRAM
sudo /usr/bin/install -o root -g wheel -m 0755 $ROOT/bin/$SINK_PROGRAM $INSTALL_ROOT/$SINK_PROGRAM
sudo /usr/bin/install -o root -g wheel -m 0755 $ROOT/bin/$RUNNER_PROGRAM $INSTALL_ROOT/$RUNNER_PROGRAM
sudo /usr/bin/install -o root -g wheel -m 0755 $ROOT/bin/$IMPORTER_PROGRAM $INSTALL_ROOT/$IMPORTER_PROGRAM

# 3. Create the state and socket roots. Every ancestor is root-owned; only the
#    broker account may read the state root, and the runner account may not.
sudo /usr/bin/install -d -o root -g wheel -m 0755 $STATE_PARENT
sudo /usr/bin/install -d -o $BROKER_USER -g wheel -m 0700 $STATE_ROOT
sudo /usr/bin/install -d -o root -g wheel -m 0755 $SOCKET_PARENT
sudo /usr/bin/install -d -o $BROKER_USER -g wheel -m 0755 $SOCKET_ROOT

# 4. Install the launch definition and start the broker.
sudo /usr/bin/install -o root -g wheel -m 0644 ./$BROKER_LABEL.plist $BROKER_PLIST
sudo launchctl bootstrap system $BROKER_PLIST

# 5. Enroll the approval signer. This is the step that decides how much an
#    approval proves, and it is the captain's alone: the key is generated in the
#    Secure Enclave by the signing UI and never leaves it, so only its public
#    half is enrolled here. There is no fallback - if this step is skipped, the
#    gateway refuses every approval rather than accepting a weaker one.
sudo -u $BROKER_USER $INSTALL_ROOT/$BROKER_PROGRAM enroll-approver \\
  --approver-id captain-ui --algorithm ecdsa-p256-sha256 \\
  --key-material "<base64 DER public key exported by the signing UI>" \\
  --attestation-ref "<path to the Secure Enclave attestation the UI produced>"
CMD
}

emit_uninstall_script() {
  emit_guard_preamble
  cat <<CMD

# Uninstall quarantines; it never deletes a directory tree. Each step validates
# its own target first, and a directory is moved aside under a timestamp rather
# than removed, so an uninstall can never destroy the audit record or take a
# neighbouring path with it. Removing the quarantine afterwards is a separate
# decision, made by a person looking at what is in it.

STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
QUARANTINE=$QUARANTINE_PARENT/uninstalled-\$STAMP

assert_fixed_path INSTALL_ROOT "$INSTALL_ROOT" 4
assert_fixed_path STATE_ROOT "$STATE_ROOT" 4
assert_fixed_path SOCKET_ROOT "$SOCKET_ROOT" 4
assert_fixed_path BROKER_PLIST "$BROKER_PLIST" 3
assert_fixed_path RUNNER_PLIST "$RUNNER_PLIST" 3
assert_fixed_path QUARANTINE "\$QUARANTINE" 4
assert_contained "$INSTALL_ROOT" "$INSTALL_PARENT"
assert_contained "$STATE_ROOT" "$STATE_PARENT"
assert_contained "$SOCKET_ROOT" "$SOCKET_PARENT"
assert_contained "\$QUARANTINE" "$QUARANTINE_PARENT"
assert_contained "$BROKER_PLIST" "$LAUNCH_DAEMONS"
assert_contained "$RUNNER_PLIST" "$LAUNCH_DAEMONS"

# 1. Stop the service before touching anything it holds open.
sudo launchctl bootout system/$BROKER_LABEL || true

# 2. Remove the two launch definitions. Exact literal file paths, checked for
#    being real files rather than symlinks, removed one at a time with rm -f.
#    No wildcard and no recursion appear anywhere in this step.
for plist in "$BROKER_PLIST" "$RUNNER_PLIST"; do
  [ -e "\$plist" ] || continue
  assert_not_symlink "\$plist"
  [ -f "\$plist" ] || { printf 'refusing: %s is not a regular file\\n' "\$plist" >&2; exit 1; }
  assert_owner "\$plist" root
  sudo rm -f -- "\$plist"
done

# 3. Quarantine the three directories. mv, never a recursive delete: the state
#    root holds the audit record and every tombstone, and an uninstall that
#    destroys the evidence of what the gateway did is worse than one that leaves
#    a directory behind.
sudo /usr/bin/install -d -o root -g wheel -m 0700 "\$QUARANTINE"
for target in "$SOCKET_ROOT" "$INSTALL_ROOT" "$STATE_ROOT"; do
  [ -e "\$target" ] || continue
  assert_not_symlink "\$target"
  [ -d "\$target" ] || { printf 'refusing: %s is not a directory\\n' "\$target" >&2; exit 1; }
  sudo mv -- "\$target" "\$QUARANTINE/\$(basename "\$target")"
done

# 4. Remove the service principals last, so the quarantined state is never
#    briefly ownerless. Each account is checked to be the role account this
#    install created before it is deleted.
for account in $RUNNER_USER $BROKER_USER; do
  home=\$(dscl . -read /Users/"\$account" NFSHomeDirectory 2>/dev/null | awk '{print \$2}') || home=
  [ -n "\$home" ] || continue
  [ "\$home" = "$ROLE_ACCOUNT_HOME" ] || {
    printf 'refusing: %s has home %s, not the role-account home %s\\n' "\$account" "\$home" "$ROLE_ACCOUNT_HOME" >&2
    exit 1; }
  sudo sysadminctl -deleteUser "\$account"
done

printf 'Uninstalled. The previous state is quarantined at %s.\\n' "\$QUARANTINE"
printf 'Nothing was deleted recursively. Review that directory, then remove it\\n'
printf 'yourself once you are satisfied the audit record is no longer needed.\\n'
CMD
}

emit_preview() {
  cat <<TXT
Action gateway v2 activation preview
====================================

NOTHING BELOW HAS BEEN DONE. This is what installation would do, printed so it
can be reviewed before anyone runs it.

Principals
  broker  $BROKER_USER   owns $STATE_ROOT, serves the three sockets
  runner  $RUNNER_USER   holds one execution capability, cannot read the state root
  The separation is the security property. One account for both would make the
  runner able to read every capability hash and every approval in the database,
  which is exactly what the execution socket exists to avoid.

Programs, with the bytes that would be installed
  $BROKER_PROGRAM    $(program_digest "$BROKER_PROGRAM")
  $SINK_PROGRAM      $(program_digest "$SINK_PROGRAM")
  $RUNNER_PROGRAM    $(program_digest "$RUNNER_PROGRAM")
  $IMPORTER_PROGRAM  $(program_digest "$IMPORTER_PROGRAM")
  The safe sink's digest is bound into every resolved plan. Replacing that file
  after an approval invalidates the approval instead of silently running the new
  bytes under the old consent.

Paths, owners, modes
  $INSTALL_ROOT   root:wheel 0755
  $STATE_ROOT     $BROKER_USER:wheel 0700
  $SOCKET_ROOT    $BROKER_USER:wheel 0755, each socket 0600
  $BROKER_PLIST   root:wheel 0644

Install commands, in order
$(emit_install_script)

Uninstall
  Run the rollback-preview command for the guarded uninstall script. It quarantines by
  moving directories under a timestamp and never deletes a tree, so it cannot
  destroy the audit record or take a neighbouring path with it.

What is still unproven after all of that
  Installing these definitions does not by itself prove distinct principals,
  root-owned ancestors, Secure Enclave enrollment, signed UI identity, or network
  isolation. Those are measured by bin/fm-worker-boundary-regression.sh against a
  real installation, and until that pack runs green on the installed paths, the
  honest statement is that they are planned and unverified.

Outward execution after installation
  Still none. The only executor this gateway will claim for is the deterministic
  safe sink, which appends one local record. An outward executor is a separate
  authorized change, not a consequence of installing this.
TXT
}

report_path() {  # <path> <kind>
  local path=$1 kind=$2 owner mode
  if { [ "$kind" = directory ] && [ -d "$path" ]; } || { [ "$kind" = file ] && [ -f "$path" ]; }; then
    owner=$(/usr/bin/stat -f '%Su:%Sg' "$path" 2>/dev/null || printf 'unknown')
    mode=$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null || printf '????')
    printf 'present  %s  owner=%s mode=%s\n' "$path" "$owner" "$mode"
    return 0
  fi
  printf 'absent   %s\n' "$path"
  return 1
}

emit_check() {
  local complete=0 entry path kind
  printf 'Action gateway v2 installation check\n'
  printf '====================================\n\n'
  for entry in \
    "$INSTALL_ROOT|directory" \
    "$INSTALL_ROOT/$BROKER_PROGRAM|file" \
    "$INSTALL_ROOT/$SINK_PROGRAM|file" \
    "$INSTALL_ROOT/$RUNNER_PROGRAM|file" \
    "$INSTALL_ROOT/$IMPORTER_PROGRAM|file" \
    "$STATE_ROOT|directory" \
    "$SOCKET_ROOT|directory" \
    "$BROKER_PLIST|file"; do
    path=${entry%|*}
    kind=${entry##*|}
    report_path "$path" "$kind" || complete=1
  done
  printf '\n'
  if [ "$complete" -eq 0 ]; then
    printf 'Every installed path is present. Run bin/fm-worker-boundary-regression.sh\n'
    printf 'against these paths before treating the boundary as enforced: present is\n'
    printf 'not the same as proved.\n'
    return 0
  fi
  printf 'The gateway is NOT installed. Nothing above was created by this script,\n'
  printf 'and this script will not create it. Run the preview command to see what a\n'
  printf 'captain-run installation would do.\n'
  return 3
}

write_artifacts() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || die "artifacts requires a directory"
  case "$dir" in
    -*) die "artifact directory must not start with a dash: $dir" ;;
  esac
  [ ! -L "$dir" ] || die "artifact directory is a symlink: $dir"
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "artifact path exists and is not a directory: $dir"
    [ -z "$(ls -A "$dir" 2>/dev/null)" ] || die "artifact directory must be empty: $dir"
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  launch_plist "$BROKER_LABEL" "$BROKER_USER" "$INSTALL_ROOT/$BROKER_PROGRAM" serve > "$dir/$BROKER_LABEL.plist"
  {
    printf '#!/bin/sh\n'
    printf '# Action gateway v2 install. Review every line before running any of it.\n'
    printf '# This file is an artifact for the captain to read. No agent runs it.\n'
    emit_install_script
  } > "$dir/install.sh"
  {
    printf '#!/bin/sh\n'
    printf '# Read-only. Reports what is installed; changes nothing.\n'
    printf 'set -eu\n'
    printf 'exec %s check\n' "$ROOT/bin/fm-gateway-install-v2.sh"
  } > "$dir/check.sh"
  {
    printf '#!/bin/sh\n'
    printf '# Action gateway v2 uninstall. Review every line before running any of it.\n'
    printf '# It quarantines directories by moving them; it deletes no tree.\n'
    emit_uninstall_script
  } > "$dir/uninstall.sh"
  # Deliberately not executable. These are review artifacts, and making them
  # runnable is one keystroke away from running them by accident. Each also
  # refuses to run without its explicit confirmation flag.
  chmod 0644 "$dir/$BROKER_LABEL.plist" "$dir/install.sh" "$dir/check.sh" "$dir/uninstall.sh"
  printf 'wrote %s\n' "$dir/$BROKER_LABEL.plist"
  printf 'wrote %s\n' "$dir/install.sh"
  printf 'wrote %s\n' "$dir/check.sh"
  printf 'wrote %s\n' "$dir/uninstall.sh"
  printf '\nNone of these is executable, none has been run, and install.sh and\n'
  printf 'uninstall.sh both refuse to run without %s.\n' "$CONFIRM_FLAG"
}

main() {
  assert_constants
  case "${1:-}" in
    preview)
      emit_preview
      ;;
    check)
      emit_check
      ;;
    artifacts)
      write_artifacts "${2:-}"
      ;;
    rollback-preview)
      printf 'Action gateway v2 uninstall preview\n'
      printf '===================================\n\n'
      printf 'NOTHING BELOW HAS BEEN DONE. Uninstall quarantines by moving directories\n'
      printf 'under a timestamp; it deletes no directory tree.\n\n'
      emit_uninstall_script
      ;;
    apply)
      printf 'fm-gateway-install-v2: refusing to install.\n' >&2
      printf 'Creating service accounts, writing root-owned paths, loading launch\n' >&2
      printf 'definitions, and enrolling an approver key are the captain'"'"'s own step\n' >&2
      printf 'at the Mac. Run the preview command for exactly what to do, or artifacts DIR\n' >&2
      printf 'for the files to review first.\n' >&2
      exit 3
      ;;
    -h|--help|help|'')
      usage
      ;;
    *)
      die "unknown command: $1"
      ;;
  esac
}

main "$@"
