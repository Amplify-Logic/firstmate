#!/usr/bin/env bash
# Reproduces windows-wsl.yml's "Put this commit at ~/starship" step for a
# pull_request event: the runner checkout is detached with no refs/heads/*.
# Usage: pr-shaped-fixture.sh <worktree> <sha>
set -u
WT=$1 SHA=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-prfix.XXXXXX"); trap 'rm -rf "$T"' EXIT
git clone --quiet --no-checkout "$WT" "$T/checkout"
git -C "$T/checkout" checkout --quiet --detach "$SHA"
for b in $(git -C "$T/checkout" for-each-ref --format='%(refname)' refs/heads refs/remotes); do git -C "$T/checkout" update-ref -d "$b"; done
echo "runner checkout refs/heads: $(git -C "$T/checkout" for-each-ref refs/heads | wc -l | tr -d ' ') (HEAD detached at $(git -C "$T/checkout" rev-parse --short HEAD))"
src="$T/checkout"; home="$T/home"; mkdir -p "$home"
git clone --no-checkout --quiet "$src" "$home/starship"
git -C "$home/starship" checkout --quiet --detach "$SHA"
echo "--- before the fix (origin = runner checkout):"
git -C "$home/starship" remote set-head origin --auto 2>&1 | sed 's/^/    /'; echo "    set-head exit=${PIPESTATUS[0]}"
echo "--- the fixture as committed:"
git -C "$home/starship" remote set-url origin 'https://github.com/Amplify-Logic/firstmate.git'
git -C "$home/starship" fetch --quiet origin; echo "    fetch exit=$?"
git -C "$home/starship" remote set-head origin --auto; echo "    set-head exit=$?"
echo "    origin/HEAD -> $(git -C "$home/starship" symbolic-ref refs/remotes/origin/HEAD)"
git -C "$home/starship" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main; echo "    fetch +refs/heads/main exit=$?"
git -C "$home/starship" log -1 --oneline
