# Cloud routines

A Claude Code routine is a saved prompt that Anthropic's cloud runs on a schedule, so it keeps working while the laptop is closed or asleep.
Firstmate uses routines only for fixed, read-only research over public inputs, written to one capped place the captain reviews and imports from the laptop.
The first and only routine is the weekly creator-repo watch, the cloud twin of the laptop's own creator watch.
Both run side by side; the routine does not replace the laptop watch.

Routines have no remote ingress, no gatekeeper, no messaging or spending authority, and no connectors.
Never put Compass, Artevo, Your Magical Journey, or any private repository or data into a routine: its repositories are cloned into Anthropic's cloud.

## The creator-repo watch

[`bin/fm-routine-creator-watch.sh`](../bin/fm-routine-creator-watch.sh) is the whole job, and its header owns the mechanics.
It reads tags and recent commits of a fixed list of public repositories with plain git, and writes one rolling digest, `creator-watch.md`, on the orphan branch `routine-reports` of this repository's own origin.
Each run replaces that file with one new commit, so the branch history is the audit log of every run.

The routine's saved prompt tells its model to run that one script and nothing else.
The model never reads the digest, so release names and commit subjects from other people's repositories never reach it as instructions.

| Setting | Value |
| --- | --- |
| Name at claude.ai/code/routines | firstmate creator-repo watch (public repos only) |
| Schedule | Mondays at 05:17 UTC |
| Model | Claude Haiku 4.5 |
| Tools | Bash only |
| Connectors | none; every connector the form adds by default was removed |
| Repository | this firstmate repository, which is public |
| Environment | Default, with Trusted network access |

## What it can and cannot touch

It can:

- Clone this public repository at the start of each run.
- Read public git data of the repositories listed in the script.
- Push one commit to the `routine-reports` branch, once write access is granted (see below).

It cannot:

- Use the GitHub API or github.com pages for any repository other than its own: the cloud's GitHub proxy refuses them.
- Reach hosts outside the Trusted allowlist, such as arbitrary websites.
- Use Gmail, Drive, Calendar, Docs, or any other connector.
- Read anything on the laptop, the firstmate home, or a private repository.
- Delete a branch or push a tag: the GitHub proxy refuses both.

Probe runs of the routine on 3 October 2026 confirmed the GitHub API, github.com page, and outside-host refusals, the refused push before the GitHub App is installed, and that public git reads of other repositories succeed.

The GitHub proxy does not limit which branch a push updates.
Once write access is granted, the fixed script is what keeps the routine on `routine-reports`: it pushes one non-forced commit to that branch and to no other.

## One-time setup

1. Install the Claude GitHub App on the account or organization that owns this repository's origin (Amplify-Logic for this fork), and choose only this repository.
   Without it the routine's push is refused, which is how it stayed read-only while it was being proven.
2. Turn the routine on at claude.ai/code/routines once the script is on the default branch.
3. Arm the laptop check in the firstmate home: `bin/fm-routine-report-check.sh arm`.

## Reviewing a report

[`bin/fm-routine-report-check.sh`](../bin/fm-routine-report-check.sh) is a registered watcher check, and its header owns cadence and the record.
When the branch moves, it wakes firstmate with one generic line that carries no report content.
`bin/fm-routine-report-check.sh show` then prints every report from a throwaway copy, without fetching into or changing this checkout.

## Kill switch

- Pause the routine with its on/off switch at claude.ai/code/routines, or delete it from the menu next to its name.
- From a firstmate Claude session, the routine tools can set it to disabled; they cannot delete it.
- Add a file named `PAUSED` to the `routine-reports` branch: the script then publishes nothing until it is removed.
- Uninstall the Claude GitHub App, or remove this repository from it, to take away write access entirely.
- Stop the laptop notices with `bin/fm-routine-report-check.sh disarm`.

## Cost and limits

Runs count against the Max plan's normal usage, with no separate bill and no overage unless usage credits are turned on.
One run is one short Haiku session a week.
The script bounds each git read, the whole sweep, the clone depth, and the digest size, and publishes nothing when every read fails.

## Network setting

GitHub traffic takes its own proxy at every network level, so **None** is the most restrictive setting that still reaches GitHub.
A dedicated environment with **None** can only be created in the environment dialog at claude.ai, not from the command line, so the routine uses the Default environment's **Trusted** level until one exists.
Changing the Default environment itself would also change every other cloud session.
