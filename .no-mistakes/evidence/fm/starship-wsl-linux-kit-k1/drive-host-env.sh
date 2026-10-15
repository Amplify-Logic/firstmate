#!/usr/bin/env bash
# Drives the real bin/fm-linux-setup.sh and bin/fm-bootstrap.sh from the gate
# worktree against a disposable lab home. Usage: drive-host-env.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset WSL_DISTRO_NAME SSH_CONNECTION SSH_TTY SSH_CLIENT DISPLAY WAYLAND_DISPLAY
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
printf 'manual\n' > "$LAB/config/backlog-backend"

echo "### 1. fm-linux-setup.sh on this macOS host, HOME=$LAB/sethome (fresh, empty)"
mkdir -p "$LAB/sethome"
( cd "$LAB/sethome" && HOME="$LAB/sethome" bash "$WT/bin/fm-linux-setup.sh" ); echo "exit=$?"
echo "files written under that HOME: $(find "$LAB/sethome" -mindepth 1 | wc -l | tr -d ' ')"
echo "--- unknown argument"
HOME="$LAB/sethome" bash bin/fm-linux-setup.sh --bogus >/dev/null 2>"$LAB/err"; echo "exit=$?"; head -1 "$LAB/err"
echo "--- --help"
HOME="$LAB/sethome" bash bin/fm-linux-setup.sh --help; echo "exit=$?"

boot() { env FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK_PHASE=skip "$@" bin/fm-bootstrap.sh 2>&1; }

echo
echo "### 2. bootstrap inside WSL (WSL_DISTRO_NAME set) with the projects dir on the Windows drive"
boot WSL_DISTRO_NAME=Ubuntu-24.04 FM_PROJECTS_OVERRIDE=/mnt/c/Users/fm/projects | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo
echo "### 3. same bootstrap, projects dir under /mnt/data (not a drive letter)"
boot WSL_DISTRO_NAME=Ubuntu-24.04 FM_PROJECTS_OVERRIDE=/mnt/data/projects | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo
echo "### 4. same Windows-drive projects dir, but not inside WSL"
boot FM_PROJECTS_OVERRIDE=/mnt/c/Users/fm/projects | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo
echo "### 5. WSL, home in Linux, .wslconfig turns localhost forwarding off (wslinfo/cmd.exe/wslpath are Windows tools, shimmed here)"
mkdir -p "$LAB/win" "$LAB/shim"
printf '[wsl2]\nmemory=8GB\nlocalhostForwarding=false\n' > "$LAB/win/.wslconfig"
printf '#!/usr/bin/env bash\necho "${FAKE_MODE:-nat}"\n' > "$LAB/shim/wslinfo"
printf '#!/usr/bin/env bash\nprintf "C:\\\\Users\\\\fm\\r\\n"\n' > "$LAB/shim/cmd.exe"
printf '#!/usr/bin/env bash\necho %s\n' "$LAB/win" > "$LAB/shim/wslpath"
chmod +x "$LAB/shim"/*
boot PATH="$LAB/shim:$PATH" WSL_DISTRO_NAME=Ubuntu-24.04 | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo "--- same, networking already mirrored"
boot PATH="$LAB/shim:$PATH" WSL_DISTRO_NAME=Ubuntu-24.04 FAKE_MODE=mirrored | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo
echo "### 6. macOS reached over SSH with no display: headless-server advice is Linux-only"
boot SSH_CONNECTION='10.0.0.2 50000 10.0.0.1 22' | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"
echo "advised marker present: $([ -e "$LAB/state/.host-env-headless-advised" ] && echo yes || echo no)"
