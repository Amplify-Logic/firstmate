#!/usr/bin/env bash
# Round 2: real bin/fm-bootstrap.sh against a disposable lab home on this macOS
# host. WSL is signalled the way WSL does (WSL_DISTRO_NAME); the Windows-side
# tools wslinfo/cmd.exe/wslpath do not exist on macOS, so they are PATH shims.
set -u
WT=$1; cd "$WT" || exit 1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset WSL_DISTRO_NAME SSH_CONNECTION SSH_TTY SSH_CLIENT DISPLAY WAYLAND_DISPLAY
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
printf 'manual\n' > "$LAB/config/backlog-backend"
mkdir -p "$LAB/projects/app1" "$LAB/win" "$LAB/shim"
boot() { env FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK_PHASE=skip "$@" bin/fm-bootstrap.sh 2>&1 | grep -E '^(HOST_ENV|BOOTSTRAP_INFO: headless)' || echo "(no host-env line)"; }
printf '#!/usr/bin/env bash\necho "${FAKE_MODE:-nat}"\n' > "$LAB/shim/wslinfo"
printf '#!/usr/bin/env bash\n[ -n "${FAKE_HANG:-}" ] && sleep 60\nprintf "C:\\\\Users\\\\fm\\r\\n"\n' > "$LAB/shim/cmd.exe"
printf '#!/usr/bin/env bash\necho %s\n' "$LAB/win" > "$LAB/shim/wslpath"
chmod +x "$LAB/shim"/*
SH="PATH=$LAB/shim:$PATH"

echo "### A. WSL, home + projects in the Linux home, default NAT networking, no .wslconfig (expect silence)"
boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04
echo "### B. same, .wslconfig present with memory only (forwarding default on) (expect silence)"
printf '[wsl2]\nmemory=8GB\n' > "$LAB/win/.wslconfig"; boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04
echo "### C. .wslconfig sets localhostForwarding=false, NAT networking (expect one HOST_ENV)"
printf '[wsl2]\nmemory=8GB\nlocalhostForwarding=false\n' > "$LAB/win/.wslconfig"; boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04
echo "### D. same .wslconfig but networking mirrored (expect silence)"
boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04 FAKE_MODE=mirrored
echo "### E. projects dir on the Windows drive (expect one HOST_ENV naming it)"
boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04 FM_PROJECTS_OVERRIDE=/mnt/c/Users/fm/projects FAKE_MODE=mirrored
echo "### F. /mnt/wsl (not a drive letter) (expect silence)"
boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04 FM_PROJECTS_OVERRIDE=/mnt/wsl/projects FAKE_MODE=mirrored
echo "### G. cmd.exe hangs (interop stuck): bootstrap stays bounded and silent"
s=$(date +%s); boot "$SH" WSL_DISTRO_NAME=Ubuntu-24.04 FAKE_HANG=1; echo "elapsed=$(( $(date +%s) - s ))s"
echo "### H. Windows-drive path but not WSL (expect silence)"
boot FM_PROJECTS_OVERRIDE=/mnt/c/Users/fm/projects
echo "### I. macOS over SSH with no display: headless advice is Linux-only (expect silence)"
boot SSH_CONNECTION='10.0.0.2 50000 10.0.0.1 22'
echo "advised marker present: $([ -e "$LAB/state/.host-env-headless-advised" ] && echo yes || echo no)"
