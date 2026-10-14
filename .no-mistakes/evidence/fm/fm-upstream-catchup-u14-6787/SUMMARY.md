# #6787 cherry-pick: supervision host successor survives the Stop hook's process-group teardown

All live runs used a real Claude Code 2.1.300 primary started on a private `tmux -L fm-lab` socket, with a disposable `bin/fm-lab-home.sh` lab home (supervision-host opted in, one `demo` crew task) and a disposable plain-git primary root whose `bin` is this worktree's `bin` (target) or a copy with the base `bin/fm-supervision-host.sh` (base). Each lab was torn down after its run.

| Run | Code | Injected teardown of hook group | Successor process group | Successor after teardown | Next park | Main woken again |
|---|---|---|---|---|---|---|
| 2 | target | no (harness only) | own (60201) | alive through main's turn | `take-over arm=60201` | no, wake queue empty |
| 4 | target | `kill -TERM -- -62659` | own (95472) | ALIVE | `take-over arm=95472` | no, wake queue empty |
| 3 | base | no (harness only) | shared hook group 17163 | alive (Claude 2.1.300 did not kill the group in this run) | `take-over arm=41812` | no |
| 5 | base | `kill -TERM -- -86600` | shared hook group 86600 | DEAD (`signal=TERM reason=arm-interrupted`) | none; primary saw "SUPERVISION OUTAGE ... watcher pid not running" | yes, `check: rearm-resurface` |

Run 1 (target, a crew window that went stale) also shows the successor outliving the hook group and later closing normally (`signal=none reason=actionable-stale`).

Deterministic regression tests: the two new tests in `tests/fm-supervision-host.test.sh` fail on the base host script (`base-repro-tests.log`) and pass on the target together with the neighboring pass-through and take-over tests (`target-selected-tests.log`).
