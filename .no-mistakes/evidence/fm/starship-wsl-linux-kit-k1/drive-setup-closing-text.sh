#!/usr/bin/env bash
# Runs the real bin/fm-linux-setup.sh (no --ci) to completion in a disposable
# world whose installers are PATH stubs (this macOS host has no Linux runtime),
# and prints the full person-facing transcript. Usage: <script> <worktree>
set -u
WT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-setup-world.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/bin" "$W/sys"
for t in bash sh env cat grep sed head mkdir mktemp chmod rm cp touch tr dirname; do ln -s "$(command -v $t)" "$W/bin/$t"; done
s() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
s true "exit 0"
s uname 'case "${1:-}" in -m) echo x86_64;; *) echo Linux;; esac'
s id 'echo 1000'
s sudo 'exec "$@"'
s apt-get 'for a; do case $a in *.deb) printf "#!/usr/bin/env bash\necho Google Chrome 141\n" > "$W_SYS/google-chrome"; chmod +x "$W_SYS/google-chrome";; esac; done'
s git 'case $1 in --version) echo git version 2.43.0;; clone) mkdir -p "$3/bin" "$3/.git"; touch "$3/bin/fm-primary.sh" "$3/AGENTS.md";; -C) [ -d "$2/.git" ];; esac'
cat > "$W/brew.stub" <<'B'
#!/usr/bin/env bash
bin=$(cd "$(dirname "$0")" && pwd)
case $1 in shellenv) printf 'export PATH="%s:$PATH"\n' "$bin";; install) for t in node npm gh tmux; do printf '#!/usr/bin/env bash\necho %s 1.0\n' $t > "$bin/$t"; chmod +x "$bin/$t"; done;; esac
B
chmod +x "$W/brew.stub"
s curl 'o=; u=; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift;; -*) ;; *) u=$1;; esac; shift; done
[ -n "$o" ] && { echo deb > "$o"; exit 0; }
case $u in */Homebrew/*) echo "mkdir -p \"\$HOMEBREW_PREFIX/bin\"; cp \"$W_ROOT/brew.stub\" \"\$HOMEBREW_PREFIX/bin/brew\"";;
*/claude.ai/*) echo "mkdir -p \"\$HOME/.local/bin\"; printf \"#!/usr/bin/env bash\necho 2.9.0 Claude Code\n\" > \"\$HOME/.local/bin/claude\"; chmod +x \"\$HOME/.local/bin/claude\"";; esac'
cd "$W/home"
echo "\$ curl -fsSL .../bin/fm-linux-setup.sh | bash      (stubbed installers, real script)"
PATH="$W/bin:$W/sys" HOME="$W/home" W_SYS="$W/sys" W_ROOT="$W" HOMEBREW_PREFIX="$W/linuxbrew" \
  bash "$WT/bin/fm-linux-setup.sh" < /dev/null 2>&1 | sed "s#$W#<world>#g"
echo "exit=${PIPESTATUS[0]}"
