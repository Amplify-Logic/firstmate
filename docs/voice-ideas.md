# Filing an idea from the glasses

Say a song's name and then the idea into the glasses, hum it, and firstmate files the recording on that song in Artevo and tells you where it went.
This is the firstmate half of the Artevo build plan's first journey: the song page plays the idea before any transcript exists, and it is filed as fact because you named the song.
`bin/fm-voice-idea.py`'s header and `--help` own the exact commands, environment, and state layout.

## What you hear

- "Filed to What a Life." when Artevo took the recording onto that song.
- "Saved, waiting for the desk." when firstmate is holding the recording because Artevo cannot take it right now, followed later by "Filed to What a Life." once it can.
- "Already filed to What a Life." or "Already saved, waiting for the desk." when the same recording arrives a second time.
- "Saved in Artevo, but not filed to What a Life." when Artevo kept the recording but did not put it on that song, for example because the song was renamed since.
- "I couldn't file that idea: ..." when no recording came with the words, or the recording is in a format Artevo cannot import.

Every line is Artevo's own verdict read back from its import report, never an assumption, and none carries an id or a path.

## What counts as an idea

The words must start with a song's name, and the word "idea" must follow within the next few words: "What a Life, bridge idea" or "What a Life, idea for the chorus".
Starting with "file this idea" makes the idea word unnecessary: "File this idea for What a Life, the chorus".
A song name followed by a question is still a question, so "What a Life, any ideas what to do next?" is left alone.
Anything that is not an idea stays in the mailbox for firstmate to answer as before.

The song names come from the `songs.json` Artevo keeps in the Artevo Inbox for the share-sheet shortcut, matched the way Artevo's own importer matches titles, so the longest title wins.
Firstmate keeps the last copy it read, so an idea is still recognised while the inbox is away.
When firstmate heard the song itself but the words were not recognised, it can hand the recording over with `take --song`.

## How it reaches Artevo

The recording is held under its capture id, which is the request id VoiceLoop gave it, in this home's private `data/voice-ideas/`.
Firstmate then writes a sidecar naming the song as your own word, and the recording beside it, into the Artevo Inbox, under a name that leads with the song's title.
It runs Artevo's own `captures import` on that same inbox, which copies the audio into the career root, verifies it by hash, and records the receipt that is spoken back.
It uses the real inbox rather than a folder of its own because Artevo remembers the inbox it last wrote `songs.json` into, and an import against any other folder would move the shortcut's song list.
That import also takes in anything else already waiting in the inbox, exactly as running it by hand would, and it never moves or deletes a source.
Firstmate never edits the Artevo checkout or the career root itself.

## Sending it twice makes one capture

A re-send of the same request is the same held capture, because VoiceLoop keeps the request id across its retries.
The same recording under a new request id is recognised by its content hash, answered from the first capture, and never handed over again.
Artevo's importer dedupes by content hash as well, so a recording you also shared from Voice Memos stays one capture.

## When the desk is away

There are two halves, and only one of them is here.

- **The Mac is asleep or offline.**
  The phone cannot reach the mailbox, so nothing on the Mac runs.
  VoiceLoop keeps the recording in its own on-disk outbox under the same request id and sends it again later.
  Today it sends again when the app opens, returns to the foreground, or passes its connection test, and it signals the failure with a chime and a red banner rather than saying "Saved, waiting for the desk".
  Speaking that line, and sending again while the app stays in the background, are changes to VoiceLoop in the glasses-voice project, not to firstmate.
- **The Mac is awake but Artevo is not reachable.**
  The Artevo Inbox folder is missing, Artevo's command is not installed, or its import fails.
  Firstmate holds the recording, says "Saved, waiting for the desk.", tries again on every check, and announces the receipt once it lands.

Firstmate is woken once per recording that first fails to reach Artevo, cannot be filed at all, or whose receipt could not be spoken, and `bin/fm-voice-idea.py status` lists every held idea with the reason it is waiting.

## Turning it on

`bin/fm-voice-idea.py arm` writes and registers the watcher check `state/fm-glasses-idea.check.sh`, which runs on the watcher's check sweep and at once when the mailbox changes, through the glasses file-event wait.
Arm it from the environment you want the check to keep, because it records this home and any Artevo or glasses location set at that moment.
The check sorts before the generic glasses question check, so an idea is taken before a "question waiting" wake can fire for it.
`bin/fm-voice-idea.py disarm` retires the check and keeps every held idea.

## Verification

Recorded on 2026-09-26 with `tests/fm-voice-idea.test.sh`, which fakes the mailbox, the spoken output, and Artevo's import, and runs the real ones when pointed at their checkouts:

```
$ FM_TEST_ARTEVO_CHECKOUT=<artevo-workspace checkout> \
  FM_TEST_GLASSES_CHECKOUT=<glasses-voice checkout> \
  bash tests/fm-voice-idea.test.sh
...
ok - the real Artevo importer files the idea as named, once
ok - the real glasses mailbox hears saved and waiting, then filed
```

That run used Artevo at `bd42682` against a temporary career root, and glasses-voice at `44a567d` against a temporary mailbox with no speech keys.
It proves the real importer files the recording as named on the song and makes one capture from two sends, and that the real answer and announce commands carry the waiting line and then the receipt.
It does not prove the glasses hardware, the live mailbox, the live Artevo Inbox in iCloud Drive, or VoiceLoop's own outbox, and the check has not been armed in a live home.
