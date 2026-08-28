# Ops command center

The ops command center is a Standing Order plus three organs built from primitives already in this repo.
It adds no services, daemons, or databases.
The adopted design and grafts are the rationale; this page is only the object model and the commands that implement slice 1.

## Object model

- **Standing Order** - one captain-approved markdown file at `data/orders/<slug>.md`.
  It declares what to watch, what a worker may stage, what stays the captain's last click, how urgently it reaches him, and the cleared route.
  `Status:` is required and is the arming switch.
  `DRAFT` renders and does nothing; `ARMED` lets the watch run and stage only.
  `GRADUATED: <action-kind> (captain <date>)` lines record per-kind autonomy after the captain graduates that kind.
- **Watch** - a registered `state/order-<slug>.check.sh` that the existing watcher already sweeps.
  A Watch reads a result someone else computed and prints one line when firstmate should wake, otherwise nothing.
- **Tray** - the action gateway's durable records rendered by `bin/fm-tray.sh`.
  It is not a second store.
  Pending staged actions are `prepared` ActionRequests.
  AGE is the headline: oldest first, expired marked.
  The tray never approves, executes, or mutates gateway state.
  Approval stays on `bin/fm-action-gateway.sh` captain-role commands.
- **Errand** - a named connector job the primary runs itself because hosted connectors are invisible to workers.
  Prompt and output contract live at `data/errands/<slug>.md`; results land as dated snapshots under `data/ops/`.
  Slice 1 does not add an errand runner.

## Commands

Exact flags, Status rewrite rules, and refusal text are owned by each script's header and `--help`.

- `bin/fm-order.sh` - list, show, run, arm, disarm, graduate.
  Arm, disarm, and graduate require `--by-captain`.
  Graduate calls `fm-action-gateway.sh classify` and refuses any kind that classifier treats as non-graduatable.
- `bin/fm-tray.sh` - pending table, `counts` line (`TRAY <n> · OLDEST <age>`), and `show <digest>`.

New outward kinds for this slice live in the gateway's deny-by-default registry: `device.config.push` and `device.firmware.push` (irreversible), `kb.fact.publish`, `course.publish`, and `sheet.write` (external).
See [`action-gateway.md`](action-gateway.md).

## Rationale

The adopted skeleton, trust ladder, and grafts are private design reports, not a second copy of this page.
Do not duplicate them here.
