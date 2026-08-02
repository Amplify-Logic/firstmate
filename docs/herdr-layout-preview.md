# Herdr layout preview: what the fleet list looks like after convergence

**Status: preview only, nothing is live.**
Nothing in this document is switched on.
The live fleet still uses the layout shown under BEFORE, and it stays that way until the captain approves a change.

The decision this preview serves was already made: converge on upstream's Herdr backend and adopt its one-worker-per-container execution unit, because isolating and inspecting a single worker is genuinely better that way, but do not adopt upstream's raw visual hierarchy.
Upstream's list is flat, labelled by task slug, carries no project context, and degrades past about five workers ([`data/fm-upstream-trial-verdict-v2/report.md`](../data/fm-upstream-trial-verdict-v2/report.md) in the firstmate home, sections "One-worker-per-container: real opinion after using it" and "What ours does better").
This preview shows what upstream's worker unit looks like once our human-readable project labels are put back on top of it.

## The two-minute version

**What changes.** Today one row in the fleet list is one project, and you open it to see its workers.
After convergence one row is one worker, so a fleet of eight workers is eight rows instead of three.
Each row carries its own project name, so `Artevo · Retry the nightly artwork export · 🔴 FAILED` reads completely on its own line.

**What stays.** The words stay.
Human outcomes instead of task slugs, `NEEDS LARS` / `FAILED` / `BLOCKED` in plain capitals with their colour, and the runtime and branch on the detail row are all unchanged.
Opening a worker looks exactly like it does today.
No 22-character token is ever shown, and nothing about how work is identified or controlled changes.

**What is lost.** One thing, and it is real: the per-project count line, `Your Magical Journey · 🟣 1 NEEDS LARS · 🔵 2 WORKING`.
After convergence there is no project row left to carry it, so you read the fleet by scanning eight rows instead of three summaries.
At eight workers that is a fair trade; at thirty it would not be, and the fix for that is a small upstream request, described at the end.

**Recommendation.** Go ahead with AFTER-B below.
It is the only one of the two candidates that survives real use: I tried the version that keeps a project heading with its workers indented underneath, and it breaks the first time a worker starts out of order, which happens constantly on a real fleet.
The evidence is in this document.

## How these were produced

Every layout below was staged in a real, throwaway Herdr workspace of its own, using the guarded lab helper for every single operation including cleanup.
The live fleet was never touched, and the check that proves the live fleet was unchanged passed after each of the three runs.

The synthetic fleet is eight workers across three projects, covering every state the fleet list can show.
Seven start in project order; the eighth, `Fix the crash on the last booking step`, deliberately starts last, for a project whose other workers started first.
That eighth worker is the whole experiment: it is what a normal day looks like.

The rows are Herdr's own reported labels, read back after staging, not mock-ups.
They are printed here as text rather than photographed because taking a picture would mean attaching to the throwaway workspace, and the safety helper correctly refuses that.
Regenerate them with:

```bash
FM_HERDR_LAYOUT_PREVIEW_E2E=1 \
  FM_HERDR_LAYOUT_PREVIEW_OUT=docs/evidence/herdr-layout-preview \
  HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh \
  tests/fm-herdr-layout-preview-e2e.test.sh
```

Verified 2026-08-03 against Herdr 0.7.4 on macOS 25.5.0.
Raw captures: [`docs/evidence/herdr-layout-preview/`](evidence/herdr-layout-preview/).

## BEFORE: what you see today

Three rows, one per project, each with a running count of what its workers need.

```text
WORKSPACE  Your Magical Journey · 🟣 1 NEEDS LARS · 🔵 2 WORKING
  TAB      WORKER · Validate GPS triggers across all seven Amsterdam stops · 🔵 WORKING
  DETAIL   pi/gpt-5.6 · detached
  TAB      WORKER · Decide the canal-loop audio cut · 🟣 NEEDS LARS
  DETAIL   claude/opus-5 · fm/journey-route-audio-q2
  TAB      WORKER · Speed up the offline map tiles · 🔵 WORKING
  DETAIL   codex/gpt-5.6 · fm/journey-tile-cache-r3
WORKSPACE  Artevo · 🟣 1 NEEDS LARS · 🔴 1 FAILED
  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS LARS
  DETAIL   claude/opus-5 · fm/artevo-onboarding-copy-k4
  TAB      WORKER · Retry the nightly artwork export · 🔴 FAILED
  DETAIL   pi/gpt-5.6 · fm/artevo-export-retry-m1
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
  TAB      WORKER · Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
  DETAIL   claude/opus-5 · fm/api-platform-rate-limit-c7
  TAB      WORKER · Audit the public schema for breaking changes · 🟢 READY
  DETAIL   codex/gpt-5.6 · detached
```

`WORKSPACE` is a row in the fleet list, `TAB` is a worker inside it, `DETAIL` is that worker's runtime and branch.
Full capture: [`01-before.txt`](evidence/herdr-layout-preview/01-before.txt).

When the eighth worker starts, the list does not grow.
It joins its own project and the count on that project's row goes up:

```text
WORKSPACE  Your Magical Journey · 🟣 1 NEEDS LARS · 🔴 1 FAILED · 🔵 2 WORKING
  ...
  TAB      WORKER · Fix the crash on the last booking step · 🔴 FAILED
  DETAIL   claude/opus-5 · fm/journey-checkout-crash-t9
```

Full capture: [`02-before-late-worker.txt`](evidence/herdr-layout-preview/02-before-late-worker.txt).
This order-independence is what today's layout buys, and it is exactly what the convergence has to pay for.

## AFTER-A: a project heading with workers indented under it

The obvious way to keep project grouping on upstream's unit is to give each project a heading row and put its workers, now one row each, directly beneath it.
Staged in project order it looks almost like today:

```text
WORKSPACE  Your Magical Journey · 🟣 1 NEEDS LARS · 🔵 2 WORKING
WORKSPACE  └ Validate GPS triggers across all seven Amsterdam stops · 🔵 WORKING
WORKSPACE  └ Decide the canal-loop audio cut · 🟣 NEEDS LARS
WORKSPACE  └ Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Artevo · 🟣 1 NEEDS LARS · 🔴 1 FAILED
WORKSPACE  └ Decide the onboarding welcome copy · 🟣 NEEDS LARS
WORKSPACE  └ Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
WORKSPACE  └ Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  └ Audit the public schema for breaking changes · 🟢 READY
```

Full capture, with every worker's tab and detail row: [`03-after-a-grouped.txt`](evidence/herdr-layout-preview/03-after-a-grouped.txt).

**This is the shape that fails.**
Herdr puts a new row at the bottom of the list and offers no way to move it.
So when the eighth worker starts, for Your Magical Journey, whose heading is at the very top, it lands here instead:

```text
WORKSPACE  Your Magical Journey · 🟣 1 NEEDS LARS · 🔴 1 FAILED · 🔵 2 WORKING
WORKSPACE  └ Validate GPS triggers across all seven Amsterdam stops · 🔵 WORKING
WORKSPACE  └ Decide the canal-loop audio cut · 🟣 NEEDS LARS
WORKSPACE  └ Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Artevo · 🟣 1 NEEDS LARS · 🔴 1 FAILED
WORKSPACE  └ Decide the onboarding welcome copy · 🟣 NEEDS LARS
WORKSPACE  └ Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · 🟠 1 BLOCKED · 🟢 1 READY
WORKSPACE  └ Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  └ Audit the public schema for breaking changes · 🟢 READY
WORKSPACE  └ Fix the crash on the last booking step · 🔴 FAILED
```

Full capture: [`04-after-a-late-worker.txt`](evidence/herdr-layout-preview/04-after-a-late-worker.txt).

The last row is a Your Magical Journey worker, but it is sitting under the API Platform heading, and the indent makes it look like it belongs there.
The Journey heading four rows above correctly counts it, so the counts and the layout now disagree.
That is worse than no grouping at all: a wrong project label is a trap, and this one appears every time a worker starts out of order, which on a real fleet is most of the time.

There is no way to fix this from our side.
Ordering is fixed at creation and there is no reorder or nesting command, so any layout that relies on a row's position to say which project it belongs to is unreliable by construction.

## AFTER-B: the project name on every row (recommended)

Put the project name on the worker row itself and the layout stops depending on position:

```text
WORKSPACE  Your Magical Journey · Validate GPS triggers across all seven Amsterdam stops · 🔵 WORKING
WORKSPACE  Your Magical Journey · Decide the canal-loop audio cut · 🟣 NEEDS LARS
WORKSPACE  Your Magical Journey · Speed up the offline map tiles · 🔵 WORKING
WORKSPACE  Artevo · Decide the onboarding welcome copy · 🟣 NEEDS LARS
WORKSPACE  Artevo · Retry the nightly artwork export · 🔴 FAILED
WORKSPACE  API Platform · Stop rate limits dropping webhook deliveries · 🟠 BLOCKED
WORKSPACE  API Platform · Audit the public schema for breaking changes · 🟢 READY
```

Full capture, with every worker's tab and detail row: [`05-after-b-prefixed.txt`](evidence/herdr-layout-preview/05-after-b-prefixed.txt).

The eighth worker still lands at the bottom, and it still reads correctly:

```text
WORKSPACE  Your Magical Journey · Fix the crash on the last booking step · 🔴 FAILED
```

Full capture: [`06-after-b-late-worker.txt`](evidence/herdr-layout-preview/06-after-b-late-worker.txt).

Same eight workers, same three projects, nothing misleading, and no row that means something different depending on where it sits.

Opening any of these workers gives exactly what you get today:

```text
  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS LARS
  DETAIL   claude/opus-5 · fm/artevo-onboarding-copy-k4
```

## Side by side

| | Today (BEFORE) | AFTER-A heading + indent | AFTER-B project on each row |
|---|---|---|---|
| Rows at 8 workers, 3 projects | 3 | 11 | 8 |
| Project shown for every worker | yes | only while ordering holds | yes |
| Survives a worker starting out of order | yes | **no** | yes |
| Per-project count line | yes | yes, but can contradict the layout | no |
| `NEEDS LARS` / `FAILED` / `BLOCKED` prominent | yes | yes | yes |
| Human outcome instead of a task slug | yes | yes | yes |
| Runtime and branch visible | yes | yes | yes |
| Inside a worker | unchanged | unchanged | unchanged |
| Upstream's one-worker unit | no | yes | yes |

## What is honestly given up, and what it would take to get back

Two things go, and only one of them matters.

**The per-project count line goes, and that is a real loss.**
At eight workers, scanning eight labelled rows for a purple dot is fine.
At twenty-five it would be worse than three summary rows, and I would not recommend the change at that scale without the fix below.

**Same-project workers no longer sit together.**
They appear in the order they started.
Because every row names its project this is a scanning cost rather than a correctness problem, and sorting by urgency is not available either, for the same reason: the list order cannot be controlled.

**Getting both back is an upstream request, not a fork feature.**
Herdr would need to let a row declare a parent, or let the list be sorted, so grouping does not depend on creation order.
That is a small, well-defined ask and it benefits upstream's own supervisor tree, which has exactly the same weakness: their `└ ` child rows drift away from their parent the same way AFTER-A's did.
Worth raising with Kun Chen; worth doing regardless of whether he takes it.

## What is in this branch

Nothing here changes the live fleet.
The only change to a file the running fleet uses is a mechanical one that moved four label-formatting helpers into a library so the preview reuses the exact same state words and colours instead of copying them.
`bin/fm-visible-status.sh` behaves identically, verified by its existing tests.

- `bin/fm-visible-format-lib.sh` - the state vocabulary (`NEEDS LARS`, `FAILED`, colours, ordering), now owned in one place.
- `bin/fm-herdr-preview-lib.sh` - preview-only row builders for BEFORE, AFTER-A and AFTER-B, sourced by nothing the live fleet runs.
- `tests/fm-herdr-layout-preview-e2e.test.sh` - the opt-in lab stager that produced every capture above, and asserts the failure in AFTER-A so it cannot quietly stop being true.
- `docs/evidence/herdr-layout-preview/` - the raw captures.

If the captain approves AFTER-B, the follow-up work is adopting upstream's backend and pointing the live label writer at `fm_preview_prefixed_row`'s format.
If the captain declines, delete the two preview files, this document, and the captures; the vocabulary library stays because it is an improvement either way.
