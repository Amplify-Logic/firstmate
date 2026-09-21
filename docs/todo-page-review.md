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

Use one header and one “Needs you now” queue for explicitly verified actions and decisions, ordered by urgency then newest observation.
Use stable identities so a later ledger state supersedes the morning version, including a resolution or hand-over.
Routine changes belong outside the action queue unless classified as a real obligation.
Keep fleet conditions in “Watching”, with one summary per condition and explicitly dated counts rather than accumulated per-read totals.
Keep ticket detail and calendar below the action queue, and cleared reasons in a closed disclosure at the foot.
Retain the 15 September typography, colours, provenance vocabulary, and responsive tables.

The renderer cannot verify sources or infer obligations from arbitrary prose.
New morning output therefore needs explicit composition metadata; unstructured older pages belong in a collapsed, clearly dated reference, with retired connectivity content removed, rather than being promoted into fresh actions.
The rendering contract lives in [fm-todo-render.sh](../bin/fm-todo-render.sh); source verification remains owned by [daily-todo-freshness](../.agents/skills/daily-todo-freshness/SKILL.md).
