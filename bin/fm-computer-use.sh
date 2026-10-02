#!/usr/bin/env bash
# fm-computer-use.sh - accessibility-first macOS computer use for Firstmate:
# the pinned Peekaboo install and its check, a compact element list, a settle
# wait, and the focus and dialog guard.
#
# Usage:
#   fm-computer-use.sh check
#       Exit 0 and print nothing when the peekaboo on PATH answers --version
#       with exactly the pinned version. Otherwise print one line and exit 1:
#         "peekaboo absent - pinned <pin>"
#         "peekaboo <version> installed, pinned <pin>"
#         "peekaboo does not start: <first line of its error>"
#       Detect-only: it never installs, upgrades, or removes anything.
#   fm-computer-use.sh pin
#       Print the pinned Peekaboo version.
#   fm-computer-use.sh install-url
#       Print the release page of the pinned version.
#   fm-computer-use.sh install
#       Download the pinned macOS arm64 release, verify its sha256 against the
#       digest pinned here, unpack it into ~/.local/lib/peekaboo/<pin>/ and link
#       ~/.local/bin/peekaboo to it. User-level only: no app bundle, no login
#       item, no LaunchAgent, no privacy prompt. Refuses to replace a
#       ~/.local/bin/peekaboo that is not its own link. Removal is in
#       .agents/skills/macos-computer-use/SKILL.md.
#   fm-computer-use.sh elements --app <app> [--window-title <title>] [--all] [--max <n>] [--from <see.json>]
#       One `peekaboo see --json` read of the app's window, printed compactly:
#         "app: <app> | window: <title> | dialog: yes|no | snapshot: <id> | elements: <shown>/<total>"
#       then one line per element, "<id> <role> '<label>'" plus " = <value>",
#       " (disabled)" and " (selected)" where they apply. By default only
#       actionable elements and elements carrying readable text are listed;
#       --all lists every element. --max caps the list (default 200).
#       --from renders a saved `see --json` file instead of reading the screen.
#   fm-computer-use.sh settle --app <app> [--window-title <title>] [--timeout <s>] [--interval <s>]
#       Re-read the element list until two consecutive reads agree, then print
#       the settled list and exit 0. Exits 3 with the last list printed when
#       --timeout (default 5) passes first. --interval defaults to 0.3.
#   fm-computer-use.sh facts
#       Print the screen state the guard reads, as one JSON object:
#       frontmost_app, frontmost_bundle, focused_role, focused_label, dialogs
#       (app, title, text, buttons), idle_seconds (since the last real keyboard
#       or mouse input), microphone_in_use.
#   fm-computer-use.sh guard --app <app> [--field <text>] [--allow-dialog <kind>]... [--quiet <s>] [--facts <file>]
#       The focus and dialog guard, run immediately before any step that needs
#       the front window. Prints "allow: ..." and exits 0, or prints
#       "refuse: <reason>" and exits 1. It refuses when the frontmost app is
#       not <app> (name or bundle id), when real keyboard or mouse input
#       happened in the last --quiet seconds (default 3), when the microphone
#       is in use (dictation or a call), when a dialog is open whose kind is not
#       named by --allow-dialog, or when --field is given and the focused
#       element does not contain that text. A screen state it cannot read is a
#       refusal. --facts reads the state from a file instead of the screen.
#   fm-computer-use.sh dialog-kind <text>
#       Classify dialog text as one of: privacy, save, replace, destructive,
#       quit, other. A dialog of any kind but other is answered only when the
#       task explicitly allows that kind.
#
# Exit codes: 0 ok/allow, 1 check failure/refusal, 2 usage error, 3 settle
# timeout, 4 install failure.
#
# Facts come from System Events (frontmost app, focused element, dialogs of the
# frontmost app and of the system prompt hosts), IOHIDSystem's HIDIdleTime, and
# CoreAudio's "device is running somewhere" flag on the default input device.
# They need the Accessibility and Automation (System Events) grants the
# terminal running Firstmate already holds for screen work; nothing here asks
# for a new permission. Background input that Peekaboo posts to an app's
# process does not reset HIDIdleTime; input posted to the global event tap
# (cliclick, osascript keystroke) does.
set -u

PEEKABOO_PIN=4.5.0
PEEKABOO_RELEASE_URL="https://github.com/openclaw/Peekaboo/releases/tag/v$PEEKABOO_PIN"
PEEKABOO_TARBALL_URL="https://github.com/openclaw/Peekaboo/releases/download/v$PEEKABOO_PIN/peekaboo-macos-arm64.tar.gz"
PEEKABOO_TARBALL_SHA256=a65323e5c79a0094c860199c86f99248c60955d9803ac2fa7a62b18494186beb

# Test-only seam: a suite may point the installer at a local tarball and its
# digest, but only when tests/lib.sh has armed FM_TEST_SEAM.
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  PEEKABOO_TARBALL_URL=${FM_TEST_PEEKABOO_TARBALL_URL:-$PEEKABOO_TARBALL_URL}
  PEEKABOO_TARBALL_SHA256=${FM_TEST_PEEKABOO_TARBALL_SHA256:-$PEEKABOO_TARBALL_SHA256}
fi

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed -e '/^set -u$/d' -e 's/^# \{0,1\}//'
}

die_usage() {
  echo "fm-computer-use.sh: $1" >&2
  exit 2
}

need_python() {
  command -v python3 >/dev/null 2>&1 || { echo "fm-computer-use.sh: python3 is required" >&2; exit 2; }
}

cmd_check() {
  local out first version
  if ! command -v peekaboo >/dev/null 2>&1; then
    echo "peekaboo absent - pinned $PEEKABOO_PIN"
    return 1
  fi
  if ! out=$(peekaboo --version 2>&1); then
    first=$(printf '%s\n' "$out" | sed -n '1p')
    echo "peekaboo does not start: ${first:-no output}"
    return 1
  fi
  version=$(printf '%s\n' "$out" | sed -n 's/^Peekaboo \([0-9][0-9.]*\).*/\1/p' | sed -n '1p')
  if [ "$version" != "$PEEKABOO_PIN" ]; then
    echo "peekaboo ${version:-unrecognised} installed, pinned $PEEKABOO_PIN"
    return 1
  fi
  return 0
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

cmd_install() {
  local lib bin link tmp got
  if [ "${FM_TEST_SEAM:-}" != 1 ] && { [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; }; then
    echo "install: the pinned Peekaboo build is for Apple Silicon macOS only" >&2
    return 4
  fi
  lib="$HOME/.local/lib/peekaboo/$PEEKABOO_PIN"
  bin="$HOME/.local/bin"
  link="$bin/peekaboo"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ "$(readlink "$link" 2>/dev/null)" = "$lib/peekaboo" ] && [ -x "$lib/peekaboo" ]; then
      echo "peekaboo $PEEKABOO_PIN already installed at $link"
      return 0
    fi
    echo "install: $link exists and is not this installer's link; remove or rename it first" >&2
    return 4
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-peekaboo.XXXXXX") || return 4
  if ! curl -fsSL "$PEEKABOO_TARBALL_URL" -o "$tmp/peekaboo.tar.gz"; then
    rm -rf "$tmp"
    echo "install: download failed: $PEEKABOO_TARBALL_URL" >&2
    return 4
  fi
  got=$(sha256_of "$tmp/peekaboo.tar.gz")
  if [ "$got" != "$PEEKABOO_TARBALL_SHA256" ]; then
    rm -rf "$tmp"
    echo "install: sha256 mismatch: got $got, pinned $PEEKABOO_TARBALL_SHA256" >&2
    return 4
  fi
  if ! tar -xzf "$tmp/peekaboo.tar.gz" -C "$tmp" || [ ! -f "$tmp/peekaboo-macos-arm64/peekaboo" ]; then
    rm -rf "$tmp"
    echo "install: the release archive does not contain peekaboo-macos-arm64/peekaboo" >&2
    return 4
  fi
  mkdir -p "$lib" "$bin" || { rm -rf "$tmp"; return 4; }
  cp -R "$tmp/peekaboo-macos-arm64/." "$lib/" || { rm -rf "$tmp"; return 4; }
  chmod 0755 "$lib/peekaboo"
  rm -rf "$tmp"
  ln -s "$lib/peekaboo" "$link" || return 4
  echo "installed peekaboo $PEEKABOO_PIN at $link -> $lib/peekaboo"
}

# render_elements <see-json-file> <all:0|1> <max>
render_elements() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys

path, show_all, cap = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"fm-computer-use.sh: unreadable see output: {exc}", file=sys.stderr)
    sys.exit(1)
data = doc.get("data", doc) if isinstance(doc, dict) else {}
if not isinstance(data, dict) or not isinstance(data.get("ui_elements"), list):
    print("fm-computer-use.sh: see output has no ui_elements", file=sys.stderr)
    sys.exit(1)


def text(value):
    if value is None or isinstance(value, bool):
        return ""
    return " ".join(str(value).split())


lines = []
for el in data["ui_elements"]:
    if not isinstance(el, dict):
        continue
    role = text(el.get("role")) or "element"
    if role == "other" and text(el.get("role_description")):
        role = text(el.get("role_description")).replace(" ", "-")
    value = text(el.get("value"))
    actionable = bool(el.get("is_actionable"))
    # A label that only repeats the role ("group", "cell") or the value ("1" on
    # a switch) says nothing; take the next field, down to the identifier. An
    # actionable element keeps a role-description label such as "close button".
    generic = {text(el.get("role")).lower(), text(el.get("ax_role")).lower(), value.lower()}
    if not actionable:
        generic.add(text(el.get("role_description")).lower())
    label = ""
    for key in ("label", "title", "description", "help", "identifier"):
        candidate = text(el.get(key))
        if candidate and candidate.lower() not in generic:
            label = candidate
            break
    if not label and value:
        label, value = value, ""
    if not show_all and not actionable and not (label or value):
        continue
    line = f"{text(el.get('id')) or '?'} {role} '{label}'"
    if value and value != label:
        line += f" = {value[:80]}"
    if el.get("is_enabled") is False:
        line += " (disabled)"
    if el.get("is_selected") is True:
        line += " (selected)"
    lines.append(line)

total = len(lines)
shown = lines[:cap]
dialog = "yes" if data.get("is_dialog") else "no"
print(f"app: {text(data.get('application_name'))} | window: {text(data.get('window_title'))} | "
      f"dialog: {dialog} | snapshot: {text(data.get('snapshot_id'))} | elements: {len(shown)}/{total}")
for line in shown:
    print(line)
PY
}

# see_to_file <out> <app> [window-title]: one peekaboo read into <out>. The
# window image goes to one private, overwritten file, so the latest snapshot's
# image stays valid for snapshot-relative actions without piling up captures.
see_to_file() {
  local out=$1 app=$2 title=${3:-} dir shot
  dir="${TMPDIR:-/tmp}/fm-computer-use"
  mkdir -p "$dir" && chmod 0700 "$dir" || return 1
  shot="$dir/latest.png"
  if [ -n "$title" ]; then
    peekaboo see --app "$app" --window-title "$title" --path "$shot" --json > "$out" 2>/dev/null
  else
    peekaboo see --app "$app" --path "$shot" --json > "$out" 2>/dev/null
  fi
}

cmd_elements() {
  local app="" title="" all=0 max=200 from="" tmp rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app=${2:-}; shift 2 ;;
      --window-title) title=${2:-}; shift 2 ;;
      --all) all=1; shift ;;
      --max) max=${2:-}; shift 2 ;;
      --from) from=${2:-}; shift 2 ;;
      *) die_usage "elements: unknown argument $1" ;;
    esac
  done
  case "$max" in ''|*[!0-9]*) die_usage "elements: --max must be a whole number" ;; esac
  need_python
  if [ -n "$from" ]; then
    render_elements "$from" "$all" "$max"
    return
  fi
  [ -n "$app" ] || die_usage "elements: --app is required"
  command -v peekaboo >/dev/null 2>&1 || { echo "fm-computer-use.sh: peekaboo is not installed ($(cmd_check))" >&2; return 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-cu-see.XXXXXX") || return 1
  if see_to_file "$tmp/see.json" "$app" "$title"; then
    render_elements "$tmp/see.json" "$all" "$max"
    rc=$?
  else
    echo "fm-computer-use.sh: peekaboo see failed for $app" >&2
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

cmd_settle() {
  local app="" title="" timeout=5 interval=0.3 deadline prev="" cur
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app=${2:-}; shift 2 ;;
      --window-title) title=${2:-}; shift 2 ;;
      --timeout) timeout=${2:-}; shift 2 ;;
      --interval) interval=${2:-}; shift 2 ;;
      *) die_usage "settle: unknown argument $1" ;;
    esac
  done
  [ -n "$app" ] || die_usage "settle: --app is required"
  case "$timeout" in ''|*[!0-9]*) die_usage "settle: --timeout must be whole seconds" ;; esac
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    if [ -n "$title" ]; then
      cur=$(cmd_elements --app "$app" --window-title "$title") || return 1
    else
      cur=$(cmd_elements --app "$app") || return 1
    fi
    # The snapshot id changes on every read; compare everything else.
    if [ -n "$prev" ] && [ "$(printf '%s\n' "$cur" | sed '1s/ | snapshot: [^|]*//')" = "$(printf '%s\n' "$prev" | sed '1s/ | snapshot: [^|]*//')" ]; then
      printf '%s\n' "$cur"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "$cur"
      echo "fm-computer-use.sh: $app did not settle within ${timeout}s" >&2
      return 3
    fi
    prev=$cur
    sleep "$interval"
  done
}

FACTS_JXA='function run() {
  const se = Application("System Events");
  const out = {frontmost_app: null, frontmost_bundle: null, focused_role: null, focused_label: null, dialogs: []};
  const front = se.processes.whose({frontmost: true});
  if (front.length === 0) return JSON.stringify(out);
  const p = front[0];
  out.frontmost_app = p.name();
  try { out.frontmost_bundle = p.bundleIdentifier(); } catch (e) {}
  try {
    const f = p.attributes.byName("AXFocusedUIElement").value();
    if (f) {
      out.focused_role = f.role();
      for (const a of ["description", "title", "name", "value"]) {
        try { const v = f[a](); if (v) { out.focused_label = String(v); break; } } catch (e) {}
      }
    }
  } catch (e) {}
  const describe = (owner, w) => {
    const d = {app: owner, title: "", text: [], buttons: []};
    try { d.title = String(w.title() || w.name() || ""); } catch (e) {}
    try { d.text = w.staticTexts.value().filter(Boolean).map(String); } catch (e) {}
    try { d.buttons = w.buttons.name().filter(Boolean).map(String); } catch (e) {}
    return d;
  };
  const scan = (proc) => {
    let wins = [];
    try { wins = proc.windows(); } catch (e) { return; }
    for (const w of wins) {
      let sub = "";
      try { sub = w.subrole(); } catch (e) {}
      if (sub === "AXDialog" || sub === "AXSystemDialog") out.dialogs.push(describe(proc.name(), w));
      let sheets = [];
      try { sheets = w.sheets(); } catch (e) {}
      for (const s of sheets) out.dialogs.push(describe(proc.name(), s));
    }
  };
  scan(p);
  for (const host of ["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn"]) {
    const h = se.processes.whose({name: host});
    if (h.length > 0) scan(h[0]);
  }
  return JSON.stringify(out);
}'

cmd_facts() {
  local ui idle mic
  need_python
  command -v osascript >/dev/null 2>&1 || { echo "fm-computer-use.sh: facts need macOS (osascript)" >&2; return 1; }
  ui=$(osascript -l JavaScript -e "$FACTS_JXA" 2>/dev/null) || { echo "fm-computer-use.sh: System Events did not answer" >&2; return 1; }
  idle=$(ioreg -r -c IOHIDSystem -k HIDIdleTime -d 1 2>/dev/null | awk '/HIDIdleTime/ {printf "%.3f", $NF / 1000000000; exit}')
  mic=$(python3 - <<'PY'
import ctypes, ctypes.util, struct

def fourcc(s):
    return struct.unpack(">I", s.encode())[0]

class Address(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("element", ctypes.c_uint32)]

try:
    ca = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))
    def get_u32(obj, selector):
        addr = Address(fourcc(selector), fourcc("glob"), 0)
        value, size = ctypes.c_uint32(0), ctypes.c_uint32(4)
        status = ca.AudioObjectGetPropertyData(obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(value))
        if status != 0:
            raise OSError(status)
        return value.value
    device = get_u32(1, "dIn ")  # kAudioHardwarePropertyDefaultInputDevice
    print("true" if device and get_u32(device, "gone") else "false")  # kAudioDevicePropertyDeviceIsRunningSomewhere
except Exception:
    print("null")
PY
)
  python3 - "$ui" "${idle:-}" "$mic" <<'PY'
import json, sys
ui = json.loads(sys.argv[1])
ui["idle_seconds"] = float(sys.argv[2]) if sys.argv[2] else None
ui["microphone_in_use"] = {"true": True, "false": False}.get(sys.argv[3])
print(json.dumps(ui))
PY
}

# classify <text>: the single owner of dialog kinds.
classify() {
  python3 - "$1" <<'PY'
import re, sys
t = " ".join(sys.argv[1].lower().split())
rules = [
    ("privacy", r"would like to (access|control|record|use|receive|find)|wants? (to )?(access|control)|privacy|allow .{0,40}access|keychain|password|passcode|touch id|administrator"),
    ("save", r"save changes|do you want to save|don.t save|unsaved|before closing\?|save before"),
    ("replace", r"already exists|replace"),
    ("destructive", r"\bdelete\b|\berase\b|\bdiscard\b|move to (the )?(trash|bin)|\bremove\b|permanently"),
    ("quit", r"\bquit\b|close (the )?window|close without|log out|shut down|restart"),
]
for kind, pattern in rules:
    if re.search(pattern, t):
        print(kind)
        break
else:
    print("other")
PY
}

cmd_dialog_kind() {
  [ $# -ge 1 ] || die_usage "dialog-kind: text is required"
  need_python
  classify "$*"
}

cmd_guard() {
  local app="" field="" quiet=3 facts_file="" allowed="" facts kind dialog_text
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app=${2:-}; shift 2 ;;
      --field) field=${2:-}; shift 2 ;;
      --quiet) quiet=${2:-}; shift 2 ;;
      --facts) facts_file=${2:-}; shift 2 ;;
      --allow-dialog)
        case "${2:-}" in
          privacy|save|replace|destructive|quit|other) allowed="$allowed ${2}" ;;
          *) die_usage "guard: --allow-dialog takes privacy, save, replace, destructive, quit or other" ;;
        esac
        shift 2 ;;
      *) die_usage "guard: unknown argument $1" ;;
    esac
  done
  [ -n "$app" ] || die_usage "guard: --app is required"
  case "$quiet" in ''|*[!0-9.]*) die_usage "guard: --quiet must be seconds" ;; esac
  need_python
  if [ -n "$facts_file" ]; then
    facts=$(cat "$facts_file" 2>/dev/null) || { echo "refuse: could not read the screen state ($facts_file unreadable)"; return 1; }
  else
    facts=$(cmd_facts 2>/dev/null) || { echo "refuse: could not read the screen state"; return 1; }
  fi
  # Each dialog's kind comes from the one classifier above.
  local kinds=""
  while IFS= read -r dialog_text; do
    [ -n "$dialog_text" ] || continue
    kind=$(classify "$dialog_text")
    kinds="$kinds$kind"$'\n'
  done < <(python3 -c '
import json, sys
try:
    facts = json.loads(sys.stdin.read())
    dialogs = facts.get("dialogs") or []
except Exception:
    sys.exit(0)
for d in dialogs:
    if isinstance(d, dict):
        parts = [d.get("title") or ""] + list(d.get("text") or []) + list(d.get("buttons") or [])
        print(" ".join(" ".join(str(p) for p in parts).split()) or "untitled dialog")
' <<<"$facts")
  python3 - "$facts" "$app" "$field" "$quiet" "$allowed" "$kinds" <<'PY'
import json, sys
raw, app, field, quiet, allowed, kinds = sys.argv[1:7]
allowed = set(allowed.split())
kinds = [k for k in kinds.split("\n") if k]


def refuse(reason):
    print(f"refuse: {reason}")
    sys.exit(1)


try:
    facts = json.loads(raw)
    if not isinstance(facts, dict):
        raise ValueError("not an object")
except ValueError:
    refuse("could not read the screen state")

front = facts.get("frontmost_app")
bundle = facts.get("frontmost_bundle")
if not front:
    refuse("could not tell which app is in front")
want = app.lower()
if want not in {str(front).lower(), str(bundle or "").lower()}:
    refuse(f"{front} is in front, not {app}")

idle = facts.get("idle_seconds")
if not isinstance(idle, (int, float)):
    refuse("could not tell when the keyboard or mouse was last used")
if idle < float(quiet):
    refuse(f"the keyboard or mouse was used {idle:.1f}s ago (the captain may be typing)")

mic = facts.get("microphone_in_use")
if mic is not False:
    refuse("the microphone is in use (dictation or a call)" if mic else "could not tell whether the microphone is in use")

dialogs = [d for d in (facts.get("dialogs") or []) if isinstance(d, dict)]
for d, kind in zip(dialogs, kinds):
    if kind not in allowed:
        title = d.get("title") or " ".join((d.get("text") or [])[:1]) or "untitled"
        buttons = ", ".join(d.get("buttons") or [])
        refuse(f"a {kind} dialog is open in {d.get('app') or 'an app'}: '{title}' [{buttons}]")

if field:
    focused = " ".join(str(x) for x in (facts.get("focused_role"), facts.get("focused_label")) if x)
    if field.lower() not in focused.lower():
        refuse(f"the focused element is '{focused or 'nothing'}', not '{field}'")

summary = f"{front} in front, idle {idle:.1f}s, microphone off"
if dialogs:
    summary += ", allowed dialog: " + ", ".join(kinds)
print(f"allow: {summary}")
PY
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  pin) echo "$PEEKABOO_PIN" ;;
  install-url) echo "$PEEKABOO_RELEASE_URL" ;;
  install) shift; cmd_install "$@" ;;
  elements) shift; cmd_elements "$@" ;;
  settle) shift; cmd_settle "$@" ;;
  facts) shift; cmd_facts "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  dialog-kind) shift; cmd_dialog_kind "$@" ;;
  -h|--help|help) usage ;;
  "") usage >&2; exit 2 ;;
  *) die_usage "unknown command $1 (see --help)" ;;
esac
