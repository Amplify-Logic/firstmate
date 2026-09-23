# Daily to-do page review

The 21 September 2026 page makes the reader reconcile two documents before choosing an action.
Its first “Today” header introduces the channel ledger, including a routine ticket touch with no new message and separate fleet observations from successive reads.
“Waiting on others” and the full closed-since-morning table then intervene before a second date header introduces the morning main read.
The main read repeats Wibautstraat in the Now strip and decision cards, and Tomra in the Now strip and ticket table.
Resolved corrections compete with work in the tiles, “Corrected off the list”, closed ticket rows, and “Closed or settled”.
The result gives equal visual weight to an action, a changed sensor reading, and evidence that no action remains.

The page also conflates update time with knowledge freshness.
The ledger rebuild stamp is current, while the appended morning prose retains its earlier read times and time-bound instructions.
The old connectivity section even retains silence observations that the current intake no longer wants.
Sorting only the first document cannot resolve any of these conflicts.

## Composition direction

Use one header and one short queue of explicitly verified asks, ordered by urgency then newest observation, so an action never carries the same weight as a changed sensor reading or as evidence that nothing remains.
Give each ask an identity that outlives one render, so a later state supersedes the morning version - a resolution, a hand-over, an answered hold - instead of appearing beside it.
Routine changes belong outside that queue unless classified as a real obligation.
Keep fleet conditions grouped as conditions, with one summary each and explicitly dated counts rather than accumulated per-read totals.
Keep ticket detail and calendar below the queue, and show a cleared item once with the evidence that cleared it, so “already handled” is answered rather than resurfacing.
Retain the 15 September typography, colours, provenance vocabulary, and responsive tables.

The renderer cannot verify sources or infer obligations from arbitrary prose.
New morning output therefore needs explicit composition metadata; unstructured older pages belong in a collapsed, clearly dated reference, with retired connectivity content removed, rather than being promoted into fresh actions.
The page shape and the morning composition contract live in [fm-todo-render.sh](../bin/fm-todo-render.sh), and the durable item record behind them - identity, recorded verification, closures and the captain's page commands - in [fm-todo.sh](../bin/fm-todo.sh); source verification remains owned by [daily-todo-freshness](../.agents/skills/daily-todo-freshness/SKILL.md).
