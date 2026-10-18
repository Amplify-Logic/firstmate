# shellcheck shell=bash
# Watcher hook (bin/fm-addon.sh), sourced into bin/fm-watch.sh: the glasses
# mailbox and photo-inbox file-event wake, carried entirely by
# bin/fm-file-event-lib.sh (hook W1). With that library absent nothing is
# defined, and the watcher keeps its own terminal wait.
# shellcheck source=bin/fm-file-event-lib.sh
[ ! -r "$FM_HOOK_ROOT/bin/fm-file-event-lib.sh" ] || . "$FM_HOOK_ROOT/bin/fm-file-event-lib.sh"
