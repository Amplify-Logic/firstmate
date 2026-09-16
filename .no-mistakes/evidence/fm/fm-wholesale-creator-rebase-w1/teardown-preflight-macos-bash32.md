# tests/fm-teardown.test.sh :: herdr-preflight-missing-adapter — local macOS failure

Observed on this host (macOS, stock Bash 3.2.57, the only bash available here):

    not ok - herdr-preflight-missing-adapter: teardown continued without its required preflight

## What happens

The case copies `bin/` into the sandbox, deletes `bin/backends/herdr.sh`, and
expects `bin/fm-teardown.sh` to refuse with
"herdr teardown prerequisites are unavailable ... nothing was changed".

`bash -x` trace of the sandboxed teardown, at the point of failure:

    + . .../test-root/bin/backends/herdr.sh
    .../bin/fm-backend.sh: line 629: .../bin/backends/herdr.sh: No such file or directory
    ++ teardown_release_locks
    ++ local status=0 i
    ...
    ++ return 0

Stock Bash 3.2 treats `.` on a missing file as a special-builtin error and
terminates the shell there, with `$?` still 0 at EXIT-trap entry. The script
never reaches the `if ! fm_backend_source herdr` refusal branch, so teardown
exits 0 silently. It does NOT proceed destructively: the worktree, the task
branch, `task-x1.meta`, `task-x1.status` and `task-x1.turn-ended` all survive,
`treehouse` is never invoked and no pane close is attempted.

## Not introduced by this change

The same test, run from a pristine checkout of the creator base b85e28b5
(`git archive b85e28b5 | tar -x -C /tmp/nm-creator-base`), fails identically on
this host:

    not ok - herdr-preflight-missing-adapter: teardown continued without its required preflight
    base exit=1

`teardown_herdr_require_prerequisites` and this test case do not exist at the
fork's pre-wholesale tip 74e1a957; both arrive with the creator tree. The fork's
only diff to `bin/fm-backend.sh` versus b85e28b5 is the added
`fm_backend_resolve_executable`, which is not on this path.

`tests/fm-teardown.test.sh` runs on `ubuntu-latest` in CI (`.github/workflows/ci.yml`);
the `macos-stock-bash` job runs only a Bash 3.2 parse sweep plus the
snapshot/fleet-view suites, not this one. No Bash >= 4 is installed on this host
and no container runtime is available, so whether newer Bash returns 1 from the
failed `source` (letting the refusal branch run) could not be checked here.
