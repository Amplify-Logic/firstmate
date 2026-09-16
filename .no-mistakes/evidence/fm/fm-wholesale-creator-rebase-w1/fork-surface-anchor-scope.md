# fork-surface anchor for bin/fm-push-transition-lib.sh — recorded, not enforced

`23df7969` adds to the `herdr-worker-presentation` capability:

    modifies = bin/fm-push-transition-lib.sh
    anchor   = bin/fm-push-transition-lib.sh :: fm-visible-status\.sh

`bin/fm-fork-surface.sh check` is green with it (`FORK_SURFACE OK
capabilities=70 owned_paths=193`).

## The anchor does not fire today

Deleting the restored fork call site (`bin/fm-push-transition-lib.sh:153`) and
re-running the gate:

    call sites left: 0
    FORK_SURFACE OK capabilities=70 owned_paths=193     <-- still green

G5 in `bin/fm-fork-surface.sh` skips anchors for a capability whose scope is
`personal`:

    [ "$status" != retired ] && [ "$scope" != personal ] || continue

`herdr-worker-presentation` is `scope = personal`, so all three of its anchors
are skipped. The anchor pattern itself is correct: with the same call site
deleted and only `scope` flipped to `team`, the gate fails as intended -

    fm-fork-surface: herdr-worker-presentation: anchor missing in
    bin/fm-push-transition-lib.sh: fm-visible-status\.sh; restore the fork edit
    or update the declaration in the same change

Both mutations were reverted; the worktree is clean and the gate is green.

So the declaration correctly records where the code now lives, and it will bite
the moment the capability stops being personal-scope - but as of this commit it
is a record, not a guard. The two pre-existing anchors on this capability
(`bin/fm-spawn.sh`, `bin/fm-visible-status.sh`) are inert for the same reason.
Behavioural cover for the call site is real and independent of the anchor:
`tests/fm-supervision-events.test.sh` fails when the call site is removed.
