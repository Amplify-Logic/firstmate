#!/usr/bin/env bash
# Build and launch the Mac desk push-to-talk floater for this Firstmate home.
#
# Usage:
#   fm-desk-floater.sh [--build-only]
#   fm-desk-floater.sh --help
#
# Requires macOS with Swift 5.9+, microphone permission on first use, and
# DEEPGRAM_API_KEY in the environment or this home's gitignored .env. The global
# hotkeys and typing dictated text into other apps also need the Accessibility
# permission, and screenshots the Screen Recording permission. Sending dictation
# typed into the Firstmate chat needs the Automation permission for Terminal,
# asked on first use.
# See docs/desk-floater.md.
#
# Builds desk-floater/ into a minimal .app under desk-floater/.build/DeskFloater.app
# so TCC microphone prompts have an NSMicrophoneUsageDescription.
#
# Signing: macOS keeps the Accessibility and Screen Recording grants only for
# the same signing identity and bundle identifier. Each assembled app is signed
# with the identity in this home's private config/desk-floater-signing-identity
# (a SHA-1 hash or a name as codesign accepts it, or "-" for ad-hoc), else with
# the first valid "Apple Development" codesigning identity in the keychain, so
# a rebuild keeps its grants. With neither, the linker's ad-hoc signature stays
# and macOS asks again after every rebuild. A configured identity that is
# missing or fails to sign stops the run; a keychain one that fails to sign
# falls back to ad-hoc with a note. An existing app whose bundle identifier or
# signature differs from what this run wants is reassembled without recompiling.
#
# Only a launched build carries the identifier macOS reopens by,
# com.firstmate.desk-floater. A --build-only copy, such as a verification build
# in a task worktree, is com.firstmate.desk-floater.build-only, so "Quit &
# Reopen", Finder and login items never start it in place of this home's
# floater. Launching also drops LaunchServices' record of every other copy
# registered under the launched identifier (a few seconds, after the floater
# is already up); the files themselves are never touched.
#
# Environment: FM_HOME selects the home whose config/ is read and that the
# floater serves (default: this code root). FM_DESK_FLOATER_LSREGISTER overrides
# the lsregister path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
PKG="$ROOT/desk-floater"
RELEASE_BIN="$PKG/.build/release/DeskFloater"
APP_DIR="$PKG/.build/DeskFloater.app"
APP_MACOS="$APP_DIR/Contents/MacOS"
APP_BIN="$APP_MACOS/DeskFloater"
LAUNCH_ID="com.firstmate.desk-floater"
BUILD_ONLY_ID="com.firstmate.desk-floater.build-only"
IDENTITY_FILE="$FM_HOME/config/desk-floater-signing-identity"
LSREGISTER="${FM_DESK_FLOATER_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

# Chosen signing identity: SIGN_HASH is "-" for ad-hoc; SIGN_SOURCE is
# config, keychain, or none.
SIGN_HASH="-"
SIGN_NAME=""
SIGN_SOURCE="none"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-desk-floater: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

write_info_plist() {
  local bundle_id="$1"
  cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleName</key>
  <string>DeskFloater</string>
  <key>CFBundleExecutable</key>
  <string>DeskFloater</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Desk floater records push-to-talk audio so Firstmate can hear your captain input via Deepgram.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Desk floater asks Terminal which tab is in front, so dictation into the Firstmate chat is sent rather than only pasted.</string>
</dict>
</plist>
PLIST
}

# Picks the signing identity from config/desk-floater-signing-identity, else
# the keychain's first valid "Apple Development" identity, else ad-hoc.
choose_identity() {
  local configured="" found
  if [ -f "$IDENTITY_FILE" ]; then
    configured=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$IDENTITY_FILE")
  fi
  if [ "$configured" = "-" ]; then
    SIGN_SOURCE=config
    return 0
  fi
  found=$(security find-identity -v -p codesigning 2>/dev/null | awk -v want="$configured" '
    $2 ~ /^[0-9A-Fa-f]+$/ && length($2) == 40 && index($0, "\"") > 0 {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/"[^"]*$/, "", name)
      if (want == "" ? index(name, "Apple Development:") == 1 : (toupper($2) == toupper(want) || index(name, want) > 0)) {
        print $2 "\t" name
        exit
      }
    }
  ') || found=""
  if [ -n "$found" ]; then
    SIGN_HASH="${found%%	*}"
    SIGN_NAME="${found#*	}"
    if [ -n "$configured" ]; then SIGN_SOURCE=config; else SIGN_SOURCE=keychain; fi
    return 0
  fi
  [ -z "$configured" ] || die "signing identity '$configured' from $IDENTITY_FILE is not a valid codesigning identity in the keychain"
}

# True when the assembled app already has this bundle identifier and the
# chosen signature, so nothing needs reassembling.
app_is_current() {
  local bundle_id="$1" details authority
  [ -x "$APP_BIN" ] || return 1
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_DIR/Contents/Info.plist" 2>/dev/null)" = "$bundle_id" ] || return 1
  details=$(codesign -dvv "$APP_DIR" 2>&1) || return 1
  if [ "$SIGN_HASH" = "-" ]; then
    printf '%s\n' "$details" | grep -qx 'Signature=adhoc'
    return
  fi
  authority=$(printf '%s\n' "$details" | awk '/^Authority=/ { sub(/^Authority=/, ""); print; exit }')
  printf '%s\n' "$details" | grep -qxF "Identifier=$bundle_id" && [ "$authority" = "$SIGN_NAME" ]
}

# Replaces the binary by rename rather than writing over it in place, which
# would disturb a floater still running from it, and drops the old bundle seal.
copy_app_files() {
  mkdir -p "$APP_MACOS"
  rm -rf "$APP_DIR/Contents/_CodeSignature"
  cp "$RELEASE_BIN" "$APP_BIN.new"
  chmod +x "$APP_BIN.new"
  mv -f "$APP_BIN.new" "$APP_BIN"
  write_info_plist "$1"
}

assemble_app() {
  local bundle_id="$1"
  [ -x "$RELEASE_BIN" ] || die "expected binary missing: $RELEASE_BIN"
  copy_app_files "$bundle_id"
  if [ "$SIGN_HASH" = "-" ]; then
    if [ "$SIGN_SOURCE" = none ]; then
      note "no Apple Development signing identity found; keeping the ad-hoc signature, so macOS asks for Accessibility and Screen Recording again after every rebuild"
    fi
    return 0
  fi
  if codesign --force --sign "$SIGN_HASH" --identifier "$bundle_id" --timestamp=none "$APP_DIR" >/dev/null 2>&1; then
    note "signed as $bundle_id with $SIGN_NAME"
    return 0
  fi
  [ "$SIGN_SOURCE" = keychain ] || die "codesign failed with the configured identity $SIGN_NAME"
  note "codesign failed with $SIGN_NAME; keeping the ad-hoc signature, so macOS asks for Accessibility and Screen Recording again after this rebuild"
  SIGN_HASH="-"
  copy_app_files "$bundle_id"
}

build() {
  command -v swift >/dev/null 2>&1 || die "swift is not installed"
  [ "$(uname -s)" = Darwin ] || die "the desk floater is macOS-only"
  note "building DeskFloater (release)"
  (
    cd "$PKG"
    swift build -c release --product DeskFloater
  ) || die "swift build failed"
  [ -x "$RELEASE_BIN" ] || die "expected binary missing: $RELEASE_BIN"
}

needs_build() {
  [ ! -x "$RELEASE_BIN" ] && return 0
  [ ! -x "$APP_BIN" ] && return 0
  [ "$PKG/Sources/DeskFloater.swift" -nt "$APP_BIN" ] && return 0
  [ "$PKG/Package.swift" -nt "$APP_BIN" ] && return 0
  return 1
}

# Drops LaunchServices' record of every other copy registered under the
# launched identifier, so macOS can only reopen this one.
forget_other_copies() {
  local keep path
  [ -x "$LSREGISTER" ] || return 0
  keep=$(cd "$APP_DIR" && pwd -P)
  "$LSREGISTER" -dump Bundle 2>/dev/null | awk -v id="$LAUNCH_ID" '
    /^-----/ { if (hit && path != "") print path; path = ""; hit = 0; next }
    /^path:/ { path = $0; sub(/^path:[ \t]*/, "", path); sub(/ \(0x[0-9a-fA-F]+\)$/, "", path); next }
    /^identifier:/ { v = $0; sub(/^identifier:[ \t]*/, "", v); if (v == id) hit = 1; next }
    END { if (hit && path != "") print path }
  ' | while IFS= read -r path; do
    [ "$path" = "$keep" ] && continue
    [ "$path" = "$APP_DIR" ] && continue
    if "$LSREGISTER" -u "$path" >/dev/null 2>&1; then
      note "macOS will no longer reopen the other copy at $path"
    fi
  done
}

main() {
  local build_only=false bundle_id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --build-only) build_only=true; shift ;;
      -*) die "unexpected option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
  done

  bundle_id="$LAUNCH_ID"
  [ "$build_only" = false ] || bundle_id="$BUILD_ONLY_ID"
  choose_identity

  if needs_build; then
    build
    assemble_app "$bundle_id"
  elif ! app_is_current "$bundle_id"; then
    assemble_app "$bundle_id"
  fi

  if [ "$build_only" = true ]; then
    printf '%s\n' "$APP_DIR"
    exit 0
  fi

  export FM_HOME
  export FM_DESK_FLOATER_ROOT="$ROOT"
  note "launching floater for FM_HOME=$FM_HOME"
  if ! open --env FM_HOME="$FM_HOME" --env FM_DESK_FLOATER_ROOT="$ROOT" "$APP_DIR"; then
    note "open --env failed; launching the bundle binary directly"
    "$APP_BIN" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  forget_other_copies
}

main "$@"
