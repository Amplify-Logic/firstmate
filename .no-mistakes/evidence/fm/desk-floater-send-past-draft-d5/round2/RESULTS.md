# Round-2 live validation — desk floater send past a Claude draft (target cb805eb0)

Real Claude Code 2.1.283. tmux 3.6a on a private fm-lab socket in a disposable lab home;
Herdr 0.7.4 via bin/fm-herdr-lab.sh in named fm-lab-desk-r2* sessions (all torn down: "teardown ok").
Every send went through `bin/fm-desk-voice.sh send`, the command the floater runs.

| Scenario | Backend | Result | Evidence |
|---|---|---|---|
| Grey suggested prompt ("yes, go with Banana"/"yes, use Banana") in the box: message goes to chat, suggestion not submitted | tmux | pass x2 | tmux-ghost-transcript.txt G1/G2, tmux-ghost-claude-session.tsv |
| Grey suggested prompt ("yes, go with Apple") in the box | Herdr (53 col) | pass | herdr-narrow-transcript.txt G |
| Short message past a typed draft: sent, Claude replies, draft back in box once | tmux / Herdr | pass | tmux-transcript.txt T2, herdr-transcript.txt H1 |
| 1300- and 3200-char messages past a draft: `sent:`, no mailbox, draft back, full text in session log (len 1358/3258 incl. pasted_content wrapper) | tmux / Herdr | pass | T3/T4, H2/H3, tmux-claude-session.tsv |
| Draft is only a `[Pasted text #N]` placeholder | tmux | pass | T6 |
| Adversarial: captain already has a stash: message goes to mailbox, box draft kept, old stash intact | tmux / Herdr | pass | T5, H4 |
| Busy mid-turn, narrow pane, footer shows `esc to int…` and a bare `› stashed` row (the round-1 failure layout): message sent/queued, draft restored, no mailbox | tmux 54 col / Herdr 53 col | pass | tmux-narrow-v2-N2-frames.txt + tmux-narrow-v2-transcript.txt N2; herdr-narrow-v2-H2-frames.txt + herdr-narrow-v2-transcript.txt H2 |
| Busy mid-turn, narrow pane, other footer layouts (effort toast / Draft restored toast) | tmux / Herdr | pass | N1/H1 in *-narrow-v2-*, N1/N2 in tmux-transcript.txt, H5.1/H5.2 in herdr-transcript.txt |

Note: rows labelled `fail (busy=0)` / `-narrow-mid-turn-past-draft: fail` in the transcripts are a driver
check artifact: Claude hides `esc to int…` while the box holds text and during the thinking phase, so the
footer grep read idle. The sampled frames and "Crafting…/streaming list" screens show Claude was busy; each of
those sends printed `sent:`, the draft came back in the box and the mailbox stayed empty. In H2 (Herdr) the
80-item list outlasted the 120s reply wait; the message sits queued in Claude's chat ("ctrl+enter to send now").
