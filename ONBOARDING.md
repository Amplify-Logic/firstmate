# Onboarding: blank Mac to a working first mate

You're installing an AI project manager that runs in your terminal.
You talk to it in plain English; it does the coding work, uses other AI workers to help, and reports back.
About 20 minutes, mostly waiting for installs.

This guide is for a blank macOS machine.
When you finish, you will have a running first mate that can really dispatch a worker - not just chat back.

> Your setup is yours alone.
> A fresh clone gets only the public repo - no one else's preferences, backlog, project list, or accounts.
> Your private folders (`data/`, `state/`, `config/`, `projects/`, `.env`) are created empty on first run, stay on your machine, and are gitignored forever.

---

## 1. Two accounts (browser, before the terminal)

1. **GitHub** (free) - create an account if you do not have one.
2. **One AI coding subscription** - use **Claude Code**.
   Claude Pro (~$20/mo) works; Max also works.
   Cursor, Codex, Grok, Pi, and Kimi exist and can be added later - skip them for now.

---

## 2. Six things by hand

Do exactly these six steps.
Then the first mate takes over and installs the rest after you say yes.

```sh
# 1. Homebrew - the macOS installer for developer tools
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#    When it finishes it prints two lines to run.
#    Run them, then reopen Terminal.

# 2. The three tools everything else needs
brew install git node gh

# 3. Sign in to GitHub (opens a browser)
gh auth login
#    Choose GitHub.com → HTTPS → login with a web browser.

# 4. Install Claude Code and sign in (opens a browser)
npm install -g @anthropic-ai/claude-code
claude
#    Complete the login, then type /exit.

# 5. Install Herdr - the grouped window view (from https://herdr.dev; get 0.7.4 or newer)
#    This is the one tool your first mate cannot install for you.
#    Skip it if you want the simpler view - see "Choosing your view" below.
herdr --version
#    Confirm it prints a version.

# 6. Get firstmate and start it
git clone https://github.com/Amplify-Logic/firstmate ~/starship
cd ~/starship
bin/fm-primary.sh claude
```

That opened Claude Code inside the firstmate folder.
It read its own instructions and is now your first mate.

If `bin/fm-primary.sh` refuses, run `claude` from `~/starship` instead.
Accept the project trust prompt when asked (see step 3b).

### Choosing your view (Herdr or the simple one)

**Herdr** is the richer view: every worker gets its own labelled pane, grouped by project, showing what each one is doing.
Download it from [herdr.dev](https://herdr.dev) and get **0.7.4 or newer** (protocol 16).
Older builds start but do not show the grouped labels.
It is dual-licensed **AGPL-3.0-or-later / commercial**.
You are free to install and use it as-is, and it does not affect the licence of anything you build.
Firstmate just runs it as a separate program.
**This is the one tool your first mate cannot install for you.**

**tmux** is the simpler, longest-tested option.
Fewer visuals, equally functional.
Your first mate can install it for you.

**You can switch later** by telling your first mate "use herdr" or "use tmux".

To pick durably yourself:

```sh
mkdir -p config
echo herdr > config/backend
# or: echo tmux > config/backend
```

If you launch firstmate from inside Herdr, it auto-selects Herdr and says so once.

---

## 3. Let it finish its own setup

Type:

```text
run your startup checks and tell me plainly what's missing
```

It will list tools it still needs - things like `jq`, `tmux`, `treehouse`, `no-mistakes`, and its GitHub helpers - with what each is for, and ask permission.
Say **yes, install them**.
It installs them itself via `bin/fm-bootstrap.sh install` after your consent.

The nine it can install for you after consent are: `jq`, `tmux`, `treehouse`, `no-mistakes`, `gh-axi`, `tasks-axi`, `lavish-axi`, `chrome-devtools-axi`, and `quota-axi`.

If it names something it cannot install for you - Herdr is the only one - it gives you the link.
Follow it, then say **check again**.

### 3b. Accept the trust prompt

The first time an agent runs in this folder it asks whether to trust the project's setup.
**Say yes.**

That loads the guards that let your first mate notice when a worker finishes or gets stuck.
If you decline, supervision quietly degrades and it may never notice a finished worker.

For Grok this is `grok --trust` once per clone.
For Pi it is the project trust prompt on first launch.

---

## 4. Confirm it's alive

Type:

```text
ahoy, are you my first mate? one-line status please
```

You should get a reply that calls you **captain**.
If it does, chat is working.

---

## 5. Confirm it can actually work (the real test)

Chat alone is not enough.
The finish line is a really dispatched worker in an isolated copy of a project.

Type (replace with a real public GitHub project of yours, or any public repo you care about):

```text
look at my github project <owner/repo> and tell me what it does
```

What should happen:

1. It clones the project into your local projects folder.
2. It starts a worker in another window, in an isolated copy of that repo.
3. It reports back in plain English what the project does.

When that report arrives, your setup is genuinely finished - you've just seen it delegate.
Use a read-only "look at / explain" task on purpose: zero risk on your first run.

---

## 6. Troubleshooting

| You see | Do this |
|---|---|
| `command not found: brew` | Homebrew printed two `echo` lines at the end. Run them, reopen Terminal. |
| `command not found: claude` | `npm install -g @anthropic-ai/claude-code`, reopen Terminal. |
| `command not found: npm` | `brew install node`. |
| `gh: not logged in` / `NEEDS_GH_AUTH` | `gh auth login` → HTTPS → browser. |
| `MISSING: treehouse` / `MISSING: no-mistakes` | Say "install those" - it can. |
| It doesn't call you captain | You're not in the firstmate folder. `cd ~/starship`, start again. |
| `refuses another live Firstmate session` | One is already running. Close the other window, or run `tmux ls` and exit the spare session. |
| It won't start a worker | Usually `treehouse` missing or `gh` not authenticated. Ask it: "why can't you start a worker?" |
| Nothing happens for minutes | Normal - work runs in the background. Ask "what are you doing?" |
| `permission denied` on `bin/fm-primary.sh` | `chmod +x bin/*.sh` |
| `backend=herdr selected but the 'herdr' CLI is not installed` | Install it from [herdr.dev](https://herdr.dev), or say "use tmux instead". |
| `backend=herdr selected but 'jq' is not installed` | Say "install jq". |
| `herdr protocol N … older than the verified minimum` | Run `herdr update`, or download 0.7.4+ from [herdr.dev](https://herdr.dev). |
| Herdr runs but panes have no project/worker labels | Your Herdr is below protocol 16. Run `herdr update`. |
| It never notices a worker finished | The trust prompt was declined. Restart and accept it (step 3b). |

---

## 7. House rules

- It never merges a pull request without your say-so.
- It only touches projects you point it at.
- Your setup is yours alone - nothing you do is shared back to anyone.

When you later contribute an improvement, open a PR against the tracked public files only.
Your private home never enters the PR.

---

## 8. Growing the fleet (optional)

Install only what you'll use.
Once a tool is on your machine and logged in, your first mate will start choosing between them on its own.

### More AI tools

| Add | Why you'd want it | Account |
|---|---|---|
| **Cursor CLI** (`agent`) | Cheap, fast workers on Grok 4.5 / Composer | Cursor Pro |
| **Codex** (`codex`) | Another strong worker; kept available for testing | OpenAI |
| **Pi** (`pi`) | Worker, and the second-opinion checker path | Bring-your-own key |
| **Kimi** (`kimi`) | An economical orchestrator - **runs the show, does not do worker jobs** | Moonshot |
| **Grok** (`grok`) | Another orchestrator option | xAI |
| **opencode** | Another worker option | Provider-dependent |

**Kimi is orchestrator-only** - firstmate will refuse to hand it worker jobs.
That is expected, not a fault.

If you later want a **second Claude login** without disturbing your main one: make a folder, set `CLAUDE_CONFIG_DIR` to it, and log in there.
Credentials come from logging in on that machine - a config directory is **never copied between machines**.

### More of the fleet

| Add | How |
|---|---|
| **More projects** | Tell your first mate the GitHub URL (or local path) and how you want work delivered. It clones under `projects/` and keeps a local registry. |
| **Second mates** | Persistent helpers with their own isolated firstmate home for a domain of work. Ask your first mate to set one up when one project area grows large enough to need a standing helper. |
| **X mode** | Optional public replies from eligible mentions. Opt in only by placing a pairing token in a local `.env` - see `docs/configuration.md`. Off by default; nothing changes until you opt in. |

---

## See also

- [README.md](README.md) - what firstmate is
- [docs/configuration.md](docs/configuration.md) - layout, backends, and X mode
- [docs/herdr-backend.md](docs/herdr-backend.md) - Herdr details
- [docs/porting.md](docs/porting.md) - moving a private home to a second machine
