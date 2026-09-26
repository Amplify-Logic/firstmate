#!/usr/bin/env bash
# Transcribe one audio file with Deepgram (push-to-talk desk floater path).
#
# Usage:
#   fm-deepgram-stt.sh [--json] [--keep] <audio-file>
#   fm-deepgram-stt.sh --help
#
# Reads DEEPGRAM_API_KEY from the environment or the home's gitignored .env.
# Never logs the key. Default model: nova-2 (override with DEEPGRAM_STT_MODEL).
#
# Prints the transcript text on stdout (or the raw JSON with --json).
#
# --keep also keeps a copy of the audio and of Deepgram's raw reply in this
# home's private $FM_HOME/state/desk-voice/recordings/, as <utc>-<id>.<ext>
# and <utc>-<id>.json, so a report of lost words can be checked against what
# was actually recorded. Only the newest FM_DESK_RECORDINGS_KEEP (default 10,
# 1 to 999) recordings are kept; each new one removes the oldest beyond that.
# A copy that cannot be kept is noted on stderr and never stops the transcript.
# The desk floater passes --keep for every capture.
#
# Exit:
#   0  transcript printed (may be empty if Deepgram heard silence)
#   1  request failure
#   2  missing key, missing file, or bad usage
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-deepgram-lib.sh
. "$SCRIPT_DIR/fm-deepgram-lib.sh"

CURL_BIN="${FM_DEEPGRAM_CURL:-curl}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORDINGS="$STATE/desk-voice/recordings"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-deepgram-stt: %s\n' "$*" >&2
}

refuse() {
  note "$*"
  exit 2
}

die() {
  note "$*"
  exit 1
}

# Copies <audio> into the recordings folder, prunes it to the newest
# FM_DESK_RECORDINGS_KEEP recordings, and prints the new recording's path
# without its extension.
keep_recording() {  # <audio>
  local audio=$1 keep=${FM_DESK_RECORDINGS_KEEP:-10} name ext stem f s last='' excess
  case "$keep" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *)
      note "FM_DESK_RECORDINGS_KEEP must be a number from 1 to 999, keeping 10: $keep"
      keep=10
      ;;
  esac
  mkdir -p "$RECORDINGS" || return 1
  chmod 700 "$STATE/desk-voice" "$RECORDINGS" 2>/dev/null || true
  # Microseconds in the name keep name order equal to recording order for pruning.
  name=$(python3 -c 'import datetime, secrets; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + secrets.token_hex(4))') || return 1
  ext=${audio##*/}
  case "$ext" in
    *.*) ext=${ext##*.} ;;
    *) ext=audio ;;
  esac
  stem="$RECORDINGS/$name"
  (umask 077 && cp "$audio" "$stem.$ext") || return 1

  # Every file of one recording shares its name up to the extension, and
  # names sort by recording time.
  local -a stems=()
  shopt -s nullglob
  for f in "$RECORDINGS"/*; do
    s=${f%.*}
    [ "$s" = "$last" ] || stems+=("$s")
    last=$s
  done
  excess=$(( ${#stems[@]} - keep ))
  for s in "${stems[@]:0:$(( excess > 0 ? excess : 0 ))}"; do
    rm -f "$s".*
  done
  printf '%s' "$stem"
}

extract_transcript() {  # <json-file>
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
try:
    text = data["results"]["channels"][0]["alternatives"][0].get("transcript", "")
except (KeyError, IndexError, TypeError) as exc:
    print(f"fm-deepgram-stt: unexpected JSON shape: {exc}", file=sys.stderr)
    raise SystemExit(1)
sys.stdout.write(text)
if text and not text.endswith("\n"):
    sys.stdout.write("\n")
PY
}

main() {
  local json_out=false keep=false audio='' key model http tmp ctype auth_cfg kept=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --json) json_out=true; shift ;;
      --keep) keep=true; shift ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-deepgram-stt.sh [--json] [--keep] <audio-file>"
  audio=$1
  [ -f "$audio" ] || refuse "audio file not found: $audio"

  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || refuse "DEEPGRAM_API_KEY is not set (env or gitignored .env)"
  model=$(fm_deepgram_stt_model)

  case "$audio" in
    *.wav|*.WAV) ctype=audio/wav ;;
    *.mp3|*.MP3) ctype=audio/mpeg ;;
    *.m4a|*.M4A) ctype=audio/mp4 ;;
    *.webm|*.WEBM) ctype=audio/webm ;;
    *.ogg|*.OGG) ctype=audio/ogg ;;
    *) ctype=application/octet-stream ;;
  esac

  if [ "$keep" = true ]; then
    kept=$(keep_recording "$audio") || {
      note "could not keep a copy of the recording"
      kept=
    }
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deepgram-stt.XXXXXX") || die "cannot create a temporary file"
  auth_cfg=$(fm_deepgram_auth_config "$key") || {
    rm -f "$tmp"
    die "cannot create the auth config file"
  }
  trap 'rm -f "$auth_cfg"' EXIT
  http=$("$CURL_BIN" -sS -o "$tmp" -w "%{http_code}" \
    --request POST \
    --config "$auth_cfg" \
    --header "Content-Type: ${ctype}" \
    --data-binary @"$audio" \
    --url "https://api.deepgram.com/v1/listen?model=${model}&smart_format=true") || {
    rm -f "$tmp"
    die "curl failed talking to Deepgram"
  }
  rm -f "$auth_cfg"

  if [ -n "$kept" ] && ! (umask 077 && cp "$tmp" "$kept.json"); then
    note "could not keep Deepgram's reply beside the recording"
  fi

  if [ "$http" != "200" ]; then
    note "Deepgram listen failed HTTP $http"
    head -c 400 "$tmp" >&2 || true
    printf '\n' >&2
    rm -f "$tmp"
    exit 1
  fi

  if [ "$json_out" = true ]; then
    cat "$tmp"
    rm -f "$tmp"
    exit 0
  fi

  if ! extract_transcript "$tmp"; then
    rm -f "$tmp"
    die "could not parse Deepgram transcript JSON"
  fi
  rm -f "$tmp"
  exit 0
}

main "$@"
