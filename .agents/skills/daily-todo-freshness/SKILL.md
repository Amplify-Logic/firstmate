---
name: daily-todo-freshness
description: >-
  Agent-only verification procedure for any captain-facing "waiting on you" surface.
  Load before producing or updating a daily Fresh to-do, needs-you, waiting-on-you, or morning-brief page, and before claiming in chat that a person or ticket is waiting on the captain.
  Owns the clock rule, the per-ticket HubSpot timeline read, direct Slack reads, Gmail's limits, Asana, Calendar, telemetry, the other-party acknowledgement check, the pre-publish re-read, and labelling discipline.
user-invocable: false
metadata:
  internal: true
---

# daily-todo-freshness

Load this before producing or updating any captain-facing to-do, needs-you, or waiting-on-you surface, and before claiming in chat that anything is waiting on the captain.
This skill is the single owner of the verification procedure for those surfaces.
It exists because the same failure landed twice: on 2026-09-15 four tickets shown as waiting on us had already moved, and on 2026-09-21 six items shown as open were already done, three of them answered by the captain himself from the HubSpot shared inbox as `support@`.
The captain's standing corrections live in `data/captain.md` under "Communication and evidence"; this skill is how they are satisfied.

Run the stages below in order for every item that will appear on the surface.
Do not publish an item whose stage was not run; label it "cannot verify" and name the channel instead.
A surface built partly from memory or from a previous page is not verified.

## Why the obvious sweep fails

Gmail sent folder, Slack search, and HubSpot stage are exactly the three surfaces that miss the actions that matter.

- A reply composed in HubSpot as `support@` never touches the captain's Gmail, whoever wrote it.
- A HubSpot note or internal comment never moves the stage and never appears in any search index.
- Slack search lags on DMs and returns nothing for group DMs it has not indexed.
- Colleagues close tickets, and stages move between the read and the publish.

Every stage below exists to close one of those gaps.

## Stage 0 - establish the clock

1. Record the sweep start time in CEST and in UTC.
2. Every HubSpot and Gmail timestamp is UTC, printed with a trailing `Z`.
3. Convert to CEST before writing any time on the surface; never print a raw UTC value as local.
4. For the daily page, record the sweep start with `bin/fm-todo.sh sweep-start`, so a line not re-read in this sweep renders as not re-checked.

## Stage 1 - HubSpot, per ticket, in this order

For every ticket that will appear on the surface:

1. Fetch the ticket record requesting at minimum `hs_pipeline_stage`, `closed_date`, `hs_lastmodifieddate`, `hs_last_message_sent_at`, `hs_last_message_received_at`, and `hubspot_owner_id`.
2. Resolve the stage id to its label through the ticket pipeline-stage property definition; never print the numeric id and never paraphrase the stage.
3. Treat `hs_last_message_sent_at` as the tripwire for the whole shared-inbox class: if it is later than the last outbound visible in Gmail, an answer went out from the shared inbox.
4. Fetch the ticket's `EMAIL` engagements sorted newest first and read the newest inbound body and the newest outbound body; never infer an inbound's content from the stage.
5. An outbound whose from-address is the shared support inbox (`support@`) is a real reply from us regardless of who wrote it and regardless of Gmail.
6. If `hs_last_message_sent_at` has no matching `EMAIL` engagement, the message is a conversations-inbox message, an auto-acknowledgement or an agent reply; say so explicitly and claim neither that a human answered nor that nothing went out.
7. Fetch the ticket's `NOTE` engagements sorted newest first; a note mentioning `@Lars Tolhurst` makes the item his even when the stage says otherwise.
8. Recount ownership live rather than reusing a number: search tickets owned by the captain whose stage is not Closed, and break the count down by stage label.

The HubSpot tool's own help owns object types, filter syntax, and association parameters.

## Stage 2 - Slack, read directly, never via search

1. For each named counterparty, read the DM or channel history directly with the channel-read tool.
2. Known ids: Queco `D08G6R0TD2T`, Naomi `D0C2F8VAVH6`, Salla `D0C1FRAK87Q`, Sara `D08USUFHL75`, Gaspar `D0C0RLVV04B`, Valerie/Ashlyn group `C0A0WA3MLKF`, NS/Payter group `C0BG0NGUQGZ`, `#operations-tech-support` `C08DL1GGTE1`, the captain's self-DM `D08B1CRK41M`.
3. For any item whose thread is named, read the thread to its last reply and check whether the captain appears after the question.
4. Use Slack search only to discover an unknown thread, never to conclude that something is absent.
5. A zero-result search is not evidence of absence; record it as "not located".

## Stage 3 - Gmail, and know its limits

1. Search the sent folder for the captain's own sends within the sweep window.
2. Search per counterparty domain for inbound mail.
3. Never conclude "no reply was sent" from Gmail alone; Gmail is authoritative only for mail sent from the captain's own address, and every `support@` reply must come from Stage 1.

## Stage 4 - Asana

1. Fetch named tasks by gid and read `completed`, `due_on`, `modified_at`, `assignee`, and section membership.
2. Enumerate a project's open tasks through the project task list with the completed-since filter.
3. Asana task search currently ignores its text query and returns the same assigned-task page for every query; never use it to conclude a task's state.
4. Keep a gid list in the durable record instead of re-finding tasks by name.

## Stage 5 - Calendar

1. List the week's events ordered by start time in the `Europe/Amsterdam` zone.
2. Read each event's `responseStatus` for the captain's address and write "declined" where it is declined; an event on the calendar is not an event he is attending.
3. Read event descriptions, because commitments and ticket ids hide there.
4. Follow any ticket id found in a description back into Stage 1.

## Stage 6 - Telemetry

1. Read the newest snapshot for the system from the dashboard telemetry API with the bearer key held in the AtlasSupportHub local environment file.
2. Use `created_at`, the server receive time, never `generated_at`, which is the device clock and can read 2000-01-01.
3. Convert to CEST and state the age in hours.

## Stage 7 - the other-party acknowledgement check

For anything still looking open after Stages 1 to 6:

1. Before writing "no reply from him", look for the counterparty's next message in every visible channel.
2. If they thank him, confirm, or move on, he acted somewhere invisible; the item is not open.
3. Where a relationship is known to run on WhatsApp or phone, write "cannot verify, likely handled off-channel" rather than "no reply".

## Stage 8 - the pre-publish re-read, non-negotiable

1. Immediately before writing the surface, re-fetch `hs_pipeline_stage`, `closed_date`, and `hs_lastmodifieddate` for every ticket on it, and re-run the ownership recount from Stage 1.
2. Re-read the last message in any Slack thread quoted on the surface.
3. If a re-fetch shows a change, fix the line; if a line cannot be re-read, drop it to "cannot verify".
4. Stamp the surface with the re-read time, not the sweep start time.
5. For the daily page, record each successful re-read on its item with `bin/fm-todo.sh verify`, and each proven closure with `bin/fm-todo.sh close` and its evidence; that script's `--help` owns the commands, and a line with no recorded re-read is never shown as current.

A ten-minute gap between reading and publishing produced two wrong lines on 2026-09-21; the re-read is what closes it.

## Stage 9 - labelling discipline

1. Every line carries the channel it was verified on and the timestamp of that read.
2. "Cannot verify" names the specific blind spot: WhatsApp, phone, in person, the SIT platform, or a GitHub organisation not reachable from this account.
3. `support@` is not a blind spot; shared-inbox replies are readable on the ticket's `EMAIL` engagements, so never list it in a legend of unreachable channels.
4. Never publish an item as closed without evidence of the close, to the same standard as publishing it as open.
5. Never carry a ticket's state forward between updates; each surface is a fresh live read.

## Chat claims

The same procedure applies to a single sentence in chat.
Before telling the captain that a person or ticket is waiting on him, run Stages 1, 2, 7, and 8 for that item.
If they were not run, say "cannot verify" and name the channel, rather than alleging that something is owed or missed.
