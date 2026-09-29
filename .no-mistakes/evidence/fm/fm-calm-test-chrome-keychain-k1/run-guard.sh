#!/usr/bin/env bash
# Usage: run-guard.sh <file providing header+render_export_dom> <file providing test_export_dom_render_guard>
# Sources the suite header (lib.sh, TMP_ROOT, cleanup trap) and render_export_dom from the
# first file, and the test_export_dom_render_guard case from the second, then runs only that case.
set -u
HELPER_SRC=$1 TEST_SRC=$2
cd "$(dirname "$HELPER_SRC")"
BASH_SOURCE_DIR=$(dirname "$HELPER_SRC")
eval "$(sed -n '1,/^render_export_dom() {/p' "$HELPER_SRC" | sed '$d' | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$BASH_SOURCE_DIR#")"
eval "$(sed -n '/^render_export_dom() {/,/^}/p' "$HELPER_SRC")"
eval "$(sed -n '/^test_export_dom_render_guard() {/,/^}/p' "$TEST_SRC")"
test_export_dom_render_guard
