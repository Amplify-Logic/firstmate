# Round 5 live evidence (test step, target 45143acc)

Claude Code 2.1.283 (haiku), tmux 3.6a, herdr 0.7.4. Every case runs the real
`bin/fm-desk-voice.sh send` from the gate worktree against a real Claude pane
whose pid holds a disposable marked lab home's `state/.lock`. Labs torn down.

| file | what it shows |
|---|---|
| drive-tmux.sh, tmux-transcript.txt, tmux-screen-*.txt/.ansi | private fm-lab tmux socket: A (268 chars), E-m850 (~850), E-m1300 (1.3k), E-m3200 (3.2k) past a typed draft, E-m3200p past a pasted draft, E-esc (message with an injected ESC[201~ and newlines) -> `sent`, submitted whole as one prompt, draft back in the box unsent; C existing stash -> mailbox, stash and new draft kept |
| drive-herdr.sh, herdr-transcript.txt, herdr-screen-*.txt | fm-lab-* Herdr session via bin/fm-herdr-lab.sh: H0 empty box, H2 short, H4-m850, H4-m1300, H4 (3.2k) typed draft, H4p (3.2k) pasted draft -> `sent`, whole, draft back; H3 existing stash -> mailbox |
| live-e2e-claude-draft.txt | tests/fm-desk-voice-claude-draft-live-e2e.test.sh (FM_DESK_VOICE_CLAUDE_DRAFT_LIVE=1) passing |
| fm-deepgram-desk-test.txt | tests/fm-deepgram-desk.test.sh passing, including the long-paste and placeholder-draft cases |
