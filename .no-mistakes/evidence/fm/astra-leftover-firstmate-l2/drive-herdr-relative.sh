#!/usr/bin/env bash
# fm_backend_herdr_server_start_detached with PATH holding a RELATIVE entry
# (tools). Fixture `herdr` executables only, with no real Herdr lifecycle.
# The cwd copy records where it ran. HOME holds a different `tools/herdr`
# that must never be picked.
set -u
ROOT=$1; LABEL=$2
d=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-rel.XXXXXX"); mkdir -p "$d/work/tools" "$d/home/tools"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$PWD" > "$(dirname "$0")/../started"\n' > "$d/work/tools/herdr"
printf '#!/bin/sh\ntouch "$HOME/wrong-executable"\n' > "$d/home/tools/herdr"
chmod +x "$d/work/tools/herdr" "$d/home/tools/herdr"
(cd "$d/work" && PATH="tools:/usr/bin:/bin" HOME="$d/home" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_session_client() { echo herdr; }; fm_backend_herdr_server_start_detached fm-lab-fixture' _ "$ROOT"); echo "[$LABEL] start exit=$?"
for i in $(seq 1 50); do { [ -f "$d/work/started" ] || [ -f "$d/home/wrong-executable" ]; } && break; sleep 0.1; done
echo "  selected binary ran: $(cat "$d/work/started" 2>/dev/null || echo NO)"
echo "  HOME's different tools/herdr ran instead: $([ -f "$d/home/wrong-executable" ] && echo YES || echo no)"
rm -rf "$d"
