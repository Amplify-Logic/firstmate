# Desk floater: send past a Claude draft — live evidence (2026-09-26)

Claude Code 2.1.283 (haiku), tmux 3.6a, herdr 0.7.4, macOS arm64.
Every run used a disposable marked lab home (bin/fm-lab-home.sh) and a real
`bin/fm-desk-voice.sh send` against a real Claude pane whose pid held the lab's
`state/.lock`. tmux runs used a private `fm-lab` socket under `$LAB/tmux`;
Herdr runs used an `fm-lab-*` session through bin/fm-herdr-lab.sh with a PATH
wrapper that routes every herdr call through `fm-herdr-lab.sh run`. All labs
were torn down.

| file | what it shows |
|---|---|
| live-e2e-claude-draft.txt | repo live test `tests/fm-desk-voice-claude-draft-live-e2e.test.sh` passing twice (after fixing its trust-dialog race) |
| drive-desk-floater-claude.sh | tmux scenario driver (A draft, B dim placeholder, C existing stash, D pasted-text draft, E ~3.2k-char message) |
| run1/ | first driver run: A,B,C pass; D and E anomalies (see run1/screen-D-after.txt, run1/screen-E-after.txt) |
| run2/ | second driver run on a fresh Claude: A,B,C,D pass; E goes to mailbox with draft restored |
| length-sweep.txt, length-sweep-screen.txt | messages of 298/484/669/980 chars past a draft are submitted alone (draft never submitted); 1445 chars goes to mailbox |
| herdr-H0.txt | Herdr: box showing only Claude's dim `Try "…"` placeholder reads empty and the message goes straight in |
| herdr-H2.txt | Herdr: Ctrl+S through `pane send-keys`, message submitted alone, draft back in the box |
| herdr-H3.txt | Herdr: footer already shows `› stashed` -> mailbox, nothing typed, the captain's stash intact |
