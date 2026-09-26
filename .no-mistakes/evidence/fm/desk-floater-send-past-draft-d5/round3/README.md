# Round 3 live evidence: desk floater send past a Claude draft (target 8515af00)

Claude Code 2.1.283 (haiku), tmux fm-lab socket in a disposable marked lab home, and Herdr
fm-lab-* sessions through bin/fm-herdr-lab.sh. Every lab was torn down.

| file | what it shows |
|---|---|
| drive-desk-floater-claude.sh, driver-transcript.txt, screen-*.txt/.ansi | tmux: A typed draft -> sent alone, draft back; B empty box after a reply -> sent; C existing `› stashed` -> mailbox, stash and new draft kept; D pasted-text placeholder draft -> `sent`, placeholder back; E-* seven long messages (1.6k-5.8k chars, typed and pasted drafts) -> all mailbox, draft restored, none reported `sent` |
| medium/ | tmux: 524- and 939-char messages past a typed draft -> `sent`, answered, draft back; 940-char past a pasted draft -> `sent`, submitted alone, placeholder back (the model declined to echo the word; see medium/screen-E-m960p-after.txt); 1.25k and 5.8k chars -> mailbox, draft restored |
| drive-desk-floater-herdr.sh, herdr-driver-transcript.txt, herdr-screen-*.txt | Herdr: H0/H1 empty box -> sent; H2 typed draft -> sent alone, draft back; H3 existing stash -> mailbox, stash kept; H4 3.2k chars -> mailbox, draft restored; H5 ~900 chars -> sent, answered, draft back |
| herdr-run1-setupfail/ | first Herdr attempt: the driver's Down key on Claude's trust dialog was dropped, so Claude stayed on the dialog (a driver setup fault, fixed and rerun above) |
| live-e2e-claude-draft.txt | repo test tests/fm-desk-voice-claude-draft-live-e2e.test.sh passing |
| drive-suggestion.sh, suggestion-transcript.txt, screen-suggestion-*.txt | tried to get Claude to draw a grey suggested prompt (it asked "Should I land both glasses changes?" but drew no suggestion); the send into that empty box went through |
