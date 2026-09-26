# Round 4 live evidence: long floater messages past a Claude draft are pasted whole

Claude Code 2.1.283 (haiku). The fix pastes the message into the stashed box as one bracketed paste.

| file | what it shows |
|---|---|
| drive-tmux.sh, tmux-transcript.txt, tmux-screen-*.txt/.ansi | tmux 3.6a private fm-lab socket: A (268 chars), E-m1300 (1294), E-m3200 (3154) past a typed draft, E-m3200p (3156) past a pasted draft -> `sent`, submitted whole (head and tail markers in the prompt), answered, draft back in the box unsent; C existing stash -> mailbox, stash kept |
| tmux-run1-driver-check/ | first tmux run: same product results, but the driver's own draft count grepped `^❯ ` and missed Claude's NBSP prompt row (driver fault, fixed) |
| drive-herdr.sh, herdr-transcript.txt, herdr-stdout.txt, herdr-screen-*.txt | Herdr 0.7.4 fm-lab-* session: H0 empty box, H2 short, H4-m1300 (1.3k), H4 (3.2k) typed draft, H4p (3.2k) pasted draft -> `sent`, submitted whole, draft back; H3 existing stash -> mailbox |
| live-e2e-claude-draft.txt | tests/fm-desk-voice-claude-draft-live-e2e.test.sh passing |
