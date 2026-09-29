#!/usr/bin/env bash
# Drives the suite's real render_export_dom helper against the installed Google Chrome
# on a local export-shaped HTML page, recording the argv Chrome actually ran with.
set -u
SRC=$1 OUT=$2
cd "$(dirname "$SRC")"
eval "$(sed -n '1,/^render_export_dom() {/p' "$SRC" | sed '$d' | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$(dirname "$SRC")#")"
eval "$(sed -n '/^find_chrome() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^render_export_dom() {/,/^}/p' "$SRC")"
chrome=$(find_chrome) || { echo "no chrome"; exit 2; }
echo "chrome=$chrome"
"$chrome" --version
src="$TMP_ROOT/export.html"
printf '<!doctype html><html><head><title>t</title></head><body><div id="messages"><div class="user-message">KEYCHAIN_PROBE</div></div><script>document.body.insertAdjacentHTML("beforeend","<p id=js>JS_RENDERED</p>")</script></body></html>\n' >"$src"
( for i in $(seq 1 60); do ps -axo pid=,args= | grep -F -- "$TMP_ROOT/chrome-home" | grep -v grep | grep -v -- '--type=' | head -1; sleep 0.1; done ) >"$TMP_ROOT/ps.txt" &
pspid=$!
start=$(date +%s)
if report=$(render_export_dom "$chrome" "$src" "$TMP_ROOT/dom.html" test); then echo "render_export_dom: success"; else echo "render_export_dom: FAILED: $report"; fi
echo "elapsed=$(( $(date +%s) - start ))s"
wait $pspid
echo "--- browser argv observed while running ---"
sort -u "$TMP_ROOT/ps.txt" | head -1 | tr ' ' '\n' | grep -E '^--' 
echo "--- rendered DOM ---"
cat "$TMP_ROOT/dom.html"
echo "--- profile keychain/secret files ---"
ls -la "$TMP_ROOT/chrome-home-1/Library/Keychains" 2>&1 | head
cp "$TMP_ROOT/dom.html" "$OUT.dom.html"
