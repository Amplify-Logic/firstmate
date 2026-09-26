#!/usr/bin/env bash
# Live drive of bin/fm-home-port.sh charter portability against a local bare git
# transport. gh is stubbed only to report the transport private; git is real.
set -u
WT=${WT:?}
PORT="$WT/bin/fm-home-port.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-charter-live.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--jq\ .visibility*) printf 'private\n' ;;
  *--jq\ .private*) printf 'true\n' ;;
esac
SH
chmod +x "$W/bin/gh"
BARE="$W/transport.git"; git init -q --bare "$BARE"
say() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
port() { PATH="$W/bin:$PATH" TMPDIR="$W" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$BARE.insteadOf" \
  GIT_CONFIG_VALUE_0=https://github.com/captain/portable.git "$PORT" "$@"; }
tree() { printf 'transport main: '; git -C "$BARE" ls-tree -r --name-only main 2>/dev/null | grep goals | tr '\n' ' '; echo; }
mkhome() { mkdir -p "$1/data/goals"; printf '# Captain\n' >"$1/data/captain.md"; printf '# L\n' >"$1/data/learnings.md"; printf '# B\n' >"$1/data/backlog.md"; }
perfile() { awk -v L="$2" '$0 == "data = data/goals/" { print L; next } { print }' "$WT/fork-surface.conf" > "$1"; }

SRC="$W/ship-home"; HUB="$W/work-hub"; mkhome "$SRC"; mkhome "$HUB"
printf '# Alpha\nsource alpha\n' > "$SRC/data/goals/alpha.md"
printf '# Beta\nsource beta\n' > "$SRC/data/goals/beta.md"
printf 'scratch\n' > "$SRC/data/goals/notes.txt"
printf 'hub alpha (stale)\n' > "$HUB/data/goals/alpha.md"
printf 'hub-only gamma\n' > "$HUB/data/goals/gamma.md"

say "S1 manifest declares the directory entry; fork-surface check agrees with fallback"
run "$WT/bin/fm-fork-surface.sh" port-data-allowlist
run "$PORT" portable-data-entries
(cd "$WT" && run bin/fm-fork-surface.sh check)

say "S2 directory-entry push carries every charter, not notes.txt"
run port push --remote captain/portable --home "$SRC"; tree

say "S3 pull onto work hub: charters arrive, hub-only gamma kept"
run port pull --remote captain/portable --home "$HUB"
for f in alpha beta gamma; do printf 'hub %s.md: ' $f; cat "$HUB/data/goals/$f.md" | tail -1; done
ls "$HUB/data/goals"

say "S4 delete beta at source, push again: beta leaves transport, recoverable from history"
rm "$SRC/data/goals/beta.md"
run port push --remote captain/portable --home "$SRC"; tree
printf 'main~1:data/goals/beta.md -> '; git -C "$BARE" show main~1:data/goals/beta.md | tail -1
say "S4b pull again: hub keeps its beta (pull never deletes)"
run port pull --remote captain/portable --home "$HUB"; ls "$HUB/data/goals"

say "S5 switch to per-file entry (alpha only) after a directory push: beta leaves transport"
printf '# Beta\nsource beta\n' > "$SRC/data/goals/beta.md"
run port push --remote captain/portable --home "$SRC"; tree
perfile "$W/perfile.conf" 'data = data/goals/alpha.md'
FM_FORK_SURFACE_MANIFEST="$W/perfile.conf" run port push --remote captain/portable --home "$SRC"
export -n FM_FORK_SURFACE_MANIFEST 2>/dev/null; tree
say "S5b per-file export carries only alpha"
FM_FORK_SURFACE_MANIFEST="$W/perfile.conf" run "$PORT" export --home "$SRC" --dest "$W/exp-perfile"
find "$W/exp-perfile/data/goals" -type f | sed "s#$W/##"

say "S6 adversarial: symlinked charter in directory entry stops export/push"
mkhome "$W/evil"; printf 'secret-ish outside\n' > "$W/outside.md"; ln -s "$W/outside.md" "$W/evil/data/goals/linked.md"
run "$PORT" export --home "$W/evil" --dest "$W/exp-evil"; ls "$W/exp-evil/data/goals" 2>&1
run port push --remote captain/portable --home "$W/evil"; tree
say "S6b adversarial: symlinked data/goals dir with per-file entry stops export"
mkhome "$W/evil2"; rm -rf "$W/evil2/data/goals"; mkdir -p "$W/outdir"; printf 'outside\n' > "$W/outdir/alpha.md"; ln -s "$W/outdir" "$W/evil2/data/goals"
FM_FORK_SURFACE_MANIFEST="$W/perfile.conf" run "$PORT" export --home "$W/evil2" --dest "$W/exp-evil2"; ls "$W/exp-evil2/data/goals" 2>&1
say "S6c adversarial: misnamed charter in directory stops export"
mkhome "$W/evil3"; printf 'x\n' > "$W/evil3/data/goals/-dash.md"
run "$PORT" export --home "$W/evil3" --dest "$W/exp-evil3"
say "S6d adversarial: pulled transport with symlinked charter refused before writes"
CL="$W/clone"; git clone -q "$BARE" "$CL"; git -C "$CL" config user.email t@t; git -C "$CL" config user.name t
ln -s /etc/hosts "$CL/data/goals/hosts.md"; git -C "$CL" add -A; git -C "$CL" commit -qm evil; git -C "$CL" push -q origin HEAD:main
mkdir -p "$W/fresh"; run port pull --remote captain/portable --home "$W/fresh"; ls -R "$W/fresh" 2>&1 | head

say "S7 adversarial: manifest declares non-charter data entries"
for L in 'data = data/accounts/' 'data = data/projects.md' 'data = data/goals/../secondmates.md'; do
  perfile "$W/bad.conf" "$L"
  FM_FORK_SURFACE_MANIFEST="$W/bad.conf" run "$PORT" export --home "$SRC" --dest "$W/exp-bad"
done
ls "$W/exp-bad" 2>&1

say "S8 adversarial: fork-surface check fails when manifest data entry changes without the fallback"
perfile "$W/pair.conf" 'data = data/goals/alpha.md'
(cd "$WT" && FM_FORK_SURFACE_MANIFEST="$W/pair.conf" run bin/fm-fork-surface.sh check)
perfile "$W/pair2.conf" 'data = data/accounts/'
(cd "$WT" && FM_FORK_SURFACE_MANIFEST="$W/pair2.conf" run bin/fm-fork-surface.sh check)
