#!/usr/bin/env bash
# Live driver: classify real claude screens with the change's classifier (HEAD)
# and the base classifier (34f164c9), on a private tmux socket.
set -u
WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3EY3P5S8VZ8KP9M7B9YWN2H
EV=/Users/larsmusic/.no-mistakes/evidence/01M3EY3P5S8VZ8KP9M7B9YWN2H
SOCKET=${SOCKET:-fm-lab-dialogs}
WORK=${WORK:?}
BASE="$WORK/base"
if [ ! -d "$BASE/bin" ]; then
  mkdir -p "$BASE"; git -C "$WT" archive 34f164c953effc3bf89ddd10b6e9d1df40543b68 bin | tar -x -C "$BASE"
fi
mkdir -p "$WORK/shim"
REAL_TMUX=/opt/homebrew/bin/tmux
printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
classify() {  # <root> <target>
  ( . "$1/bin/fm-tmux-lib.sh"
    c=$(fm_tmux_composer_state "$2")
    caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
    nc=$(fm_composer_classify_screen "$caps" "$(fm_tmux_composer_capture "$2")" '' probe-absent)
    if fm_pane_input_pending "$2"; then d=defer; else d=inject; fi
    printf 'cursor=%s cursorless=%s injector_guard=%s' "$c" "$nc" "$d" )
}
report() {  # <label> <target>
  local label=$1 t=$2 f="$EV/screen-$1.txt"
  tmux capture-pane -p -t "$t" > "$f"
  tmux capture-pane -e -p -t "$t" -S 0 -E - > "$EV/screen-$1.ansi"
  printf '=== %s (cursor_y=%s)\n' "$label" "$(tmux display-message -p -t "$t" '#{cursor_y}')"
  printf '  HEAD 56a2c440: %s\n' "$(classify "$WT" "$t")"
  printf '  BASE 34f164c9: %s\n' "$(classify "$BASE" "$t")"
}
"$@"
