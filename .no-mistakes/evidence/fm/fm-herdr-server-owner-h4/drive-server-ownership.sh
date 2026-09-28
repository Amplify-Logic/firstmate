#!/usr/bin/env bash
# Live drive of the herdr server-ownership change against real herdr 0.7.4, in
# two throwaway fm-lab-* sessions owned by bin/fm-herdr-lab.sh. The same flow
# runs twice: once with the change's bin/ (NEW) and once with the base commit's
# bin/ (BASE) as a before/after.
# Only chosen synthetic variables are copied into the transcript; the raw
# server and pane environments stay in the disposable lab dir, which is
# removed at the end.
# Usage: drive-server-ownership.sh <worktree> <evidence-dir>
set -u
WT=$1 EVID=$2
LABHELPER="$WT/bin/fm-herdr-lab.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/base" "$LAB/task-worktree" "$LAB/out"
git -C "$WT" archive 7cf26db4c98d9262a6bb81cdc8c03ce139ffccc4 bin | tar -x -C "$LAB/base"

WATCH_VARS="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_EFFORT CLAUDE_CODE_SESSION_ID CLAUDE_PID FM_HOME FM_SUPERVISION_MODEL FM_REMOTE_JOB_ACTIVE AGENT PRIME_AGENT_BUILD_ID GROK_WORKSPACE_ROOT TRACEPARENT GIT_CONFIG_COUNT GOTMPDIR CODEX_HOME CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR PI_CODING_AGENT_DIR"

say() { printf '%s\n' "$*"; }
lab() { "$LABHELPER" "$@"; }
running_of() { lab run "$1" session list --json 2>/dev/null | jq -r --arg n "$1" '.sessions[]|select(.name==$n)|.running'; }
server_pid_of() { pgrep -f -- "server --session $1\$" | head -1; }
getsid() { python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$1" 2>/dev/null || echo gone; }
watched() {  # <env-file> : print only the watched names, value or <absent>
  local v line
  for v in $WATCH_VARS; do
    line=$(grep -m1 "^$v=" "$1" || true)
    if [ -n "$line" ]; then printf '    %-26s %s\n' "$v" "${line#*=}"; else printf '    %-26s <absent>\n' "$v"; fi
  done
}

# The caller: a long-lived job in its OWN process group (as a launchd job is),
# carrying a dead Claude primary's identity plus user config roots, whose
# first act is the deliberate server start through the product's code.
start_caller() {  # <bin-root> <session> <outfile>
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LANG=en_US.UTF-8 TERM=xterm-256color \
    CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_EFFORT=medium \
    CLAUDE_CODE_SESSION_ID=dead-session-20260928 CLAUDE_PID=99999 \
    FM_HOME="$LAB" FM_SUPERVISION_MODEL=synthetic FM_REMOTE_JOB_ACTIVE=1 \
    AGENT=rovodev_cli PRIME_AGENT_BUILD_ID=synthetic-build GROK_WORKSPACE_ROOT=/tmp/synthetic-grok \
    TRACEPARENT=00-synthetic GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=synthetic.key GIT_CONFIG_VALUE_0=x GOTMPDIR=/tmp/synthetic-gotmp \
    CODEX_HOME=/tmp/kept-codex-home CLAUDE_CODE_OAUTH_TOKEN=kept-synthetic-token \
    CLAUDE_CONFIG_DIR=/tmp/kept-claude-config PI_CODING_AGENT_DIR=/tmp/kept-pi-dir \
    perl -e 'setpgrp(0,0); exec @ARGV' bash -c '
      cd "$4" || exit 9
      . "$1/bin/fm-backend.sh"; fm_backend_source herdr
      t0=$(perl -MTime::HiRes=time -e "printf q(%.2f), time")
      out=$(fm_backend_herdr_server_ensure "$2" 2>&1); rc=$?
      t1=$(perl -MTime::HiRes=time -e "printf q(%.2f), time")
      printf "rc=%s start=%s end=%s pid=%s pgid=%s out=%s\n" "$rc" "$t0" "$t1" "$$" "$(ps -o pgid= -p $$ | tr -d " ")" "$out" > "$3"
      exec sleep 900
    ' caller "$1" "$2" "$3" "$LAB/task-worktree" </dev/null >/dev/null 2>&1 &
  local i
  for i in $(seq 1 60); do [ -s "$3" ] && return 0; sleep 0.5; done
  return 1
}

run_flow() {  # <label> <bin-root>
  local label=$1 root=$2 S out cpgid cpid spid ws pane t0 t1 rc
  S=$(lab name "srvown-$label")
  say "=== [$label] bin root: $root   lab session: $S"
  lab provision "$S" >/dev/null || { say "provision failed"; return 1; }
  lab stop "$S" >/dev/null
  sleep 1
  say "lab session provisioned then stopped via helper; running=$(running_of "$S")"

  if :; then
    say "--- read paths with the server stopped (the watcher / voice-bridge path)"
    printf 'backend=herdr\nwindow=%s:w1:p1\nworktree=%s\nkind=ship\n' "$S" "$LAB/task-worktree" > "$LAB/state/rp.meta"
    t0=$(perl -MTime::HiRes=time -e 'printf q(%.2f), time')
    out=$(env -i HOME="$HOME" PATH="$PATH" FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 CLAUDE_CODE_SESSION_ID=dead-session-20260928 \
      perl -e 'alarm 120; exec @ARGV' "$root/bin/fm-crew-state.sh" rp 2>&1); rc=$?
    t1=$(perl -MTime::HiRes=time -e 'printf q(%.2f), time')
    say "  fm-crew-state.sh rp -> rc=$rc in $(echo "$t1 - $t0" | bc)s: $out"
    say "  after fm-crew-state.sh: session running=$(running_of "$S") server_pid=$(server_pid_of "$S" || true)"
    out=$(perl -e "alarm 60; exec @ARGV" env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_capture herdr "$2:w1:p1" 5; echo "capture rc=$?"' _ "$root" "$S" 2>&1)
    say "  fm_backend_capture herdr $S:w1:p1 -> $(printf '%s' "$out" | tr '\n' ' ')"
    out=$(perl -e "alarm 60; exec @ARGV" env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_busy_state herdr "$2:w1:p1"; echo "busy rc=$?"' _ "$root" "$S" 2>&1)
    say "  fm_backend_busy_state herdr $S:w1:p1 -> $(printf '%s' "$out" | tr '\n' ' ')"
    say "  after capture+busy reads: session running=$(running_of "$S") server_pid=$(server_pid_of "$S" || true)"
    if [ "$(running_of "$S")" = true ]; then
      ps -o pid=,ppid=,pgid=,command= -p "$(server_pid_of "$S")" | sed "s/^/  read-started server ps: /"
      lab stop "$S" >/dev/null; sleep 1
      say "  (stopped the read-started server via helper; running=$(running_of "$S"))"
    fi
  fi

  say "--- deliberate start from a caller in its own process group"
  start_caller "$root" "$S" "$LAB/out/$label.caller" || { say "caller never reported"; }
  say "  caller report: $(cat "$LAB/out/$label.caller")"
  cpid=$(sed -n 's/.* pid=\([0-9]*\) .*/\1/p' "$LAB/out/$label.caller")
  cpgid=$(sed -n 's/.* pgid=\([0-9]*\) .*/\1/p' "$LAB/out/$label.caller")
  spid=$(server_pid_of "$S"); [ -n "$spid" ] || spid=999999999
  say "  running=$(running_of "$S")"
  say "  caller: pid=$cpid pgid=$cpgid sid=$(getsid "$cpid")"
  ps -o pid=,ppid=,pgid=,tty=,command= -p "$spid" | sed "s/^/  server ps: /"
  say "  server sid=$(getsid "$spid")  (server is session leader: $([ "$(getsid "$spid")" = "$spid" ] && echo yes || echo no))"
  say "  server cwd: $(lsof -a -p "$spid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')   (caller cwd: $LAB/task-worktree)"
  say "  server fd 0/1/2: $(lsof -a -p "$spid" -d 0,1,2 -Fn 2>/dev/null | sed -n 's/^n//p' | tr '\n' ' ')"
  ps eww -p "$spid" -o command= | tr ' ' '\n' > "$LAB/out/$label.server-env"
  say "  server process environment (watched names only):"
  watched "$LAB/out/$label.server-env"

  ws=$(lab run "$S" workspace create --cwd "$LAB" --label srvown --no-focus 2>/dev/null)
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
  sleep 2
  lab run "$S" pane run "$pane" "env > $LAB/out/$label.pane-env" >/dev/null
  sleep 2
  say "  new pane $pane environment (watched names only):"
  watched "$LAB/out/$label.pane-env"

  say "--- kill -KILL the caller's whole process group (what launchctl kickstart -k does)"
  kill -KILL -- "-$cpgid"; wait 2>/dev/null
  sleep 2
  say "  caller alive: $(kill -0 "$cpid" 2>/dev/null && echo yes || echo no)"
  say "  server pid $spid alive: $(kill -0 "$spid" 2>/dev/null && echo yes || echo no)"
  say "  session running=$(running_of "$S")"
  out=$(lab run "$S" pane list --workspace "${pane%%:*}" 2>&1 | jq -c '[.result.panes[]?.pane_id]' 2>/dev/null)
  say "  panes after kill: ${out:-<none: server unreachable>}"
  if [ "$(running_of "$S")" = true ]; then
    lab run "$S" pane run "$pane" "echo pane-still-alive > $LAB/out/$label.after-kill" >/dev/null 2>&1
    sleep 1
    say "  pane command after kill wrote: $(cat "$LAB/out/$label.after-kill" 2>/dev/null || echo '<nothing>')"
    say "--- server_ensure again while running (idempotent: no second server)"
    t0=$(perl -MTime::HiRes=time -e 'printf q(%.2f), time')
    env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_server_ensure "$2"; echo "ensure rc=$?"' _ "$root" "$S" 2>&1 | sed 's/^/  /'
    t1=$(perl -MTime::HiRes=time -e 'printf q(%.2f), time')
    say "  took $(echo "$t1 - $t0" | bc)s; server processes for $S: $(pgrep -f -- "server --session $S\$" | tr '\n' ' ')(first was $spid)"
  fi
  say "--- teardown"
  lab teardown "$S" && say "  teardown ok (default-session tripwire verified)" || say "  TEARDOWN FAILED"
  say
}

run_flow NEW "$WT"
run_flow BASE "$LAB/base"
rm -rf "$LAB"
say "lab dir removed: $([ -e "$LAB" ] && echo no || echo yes)"
