#!/usr/bin/env python3
# fm-pr-text-guard.py - the worker PR text check: before a spawned Claude
# worker publishes text to a public repository's pull requests, it refuses the
# command when the text holds a word from this home's private word list.
#
# Usage:
#   fm-pr-text-guard.py hook --home DIR
#       The Claude Code PreToolUse hook on Bash that bin/fm-spawn.sh installs
#       for every spawned Claude worker (ship or scout). Reads the hook payload
#       on stdin. On a refusal it prints the documented PreToolUse deny object
#       on stdout; on an allow it prints nothing. It always exits 0.
#
# docs/configuration.md "Private leak words" owns the operator contract. The
# word list, its format and where it is found belong to bin/fm-leak-guard.sh,
# whose --text mode this hook runs with FM_HOME set to DIR; this file never
# reads the list itself.
#
# WHAT IS CHECKED. Only a Bash command that publishes text: gh or gh-axi
# `pr|issue create|edit|comment|review|close|merge`, a `gh api` call that sends
# fields or an input file, and `no-mistakes axi run|respond`, whose intent and
# answers reach the PR the pipeline writes. Every other command passes
# untouched, and so does every other tool. The text checked is the whole
# command, so inline titles, bodies, heredocs and variables set earlier in the
# same command all count, plus every file it names as a body or input
# (--body-file, -F, --input, field=@file). A listed word in a path or branch
# name of such a command is refused too, because a branch name is published.
#
# PUBLIC ONLY. A private repository may hold these words, so a hit is refused
# only when the target is public: `gh repo view` reads the repository from
# --repo/-R, from a repos/<owner>/<repo> API path, or else gh's own default for
# the working directory, the one the command itself would reach. For
# no-mistakes, the target is the origin remote; one not on github.com is not
# checked. A repository whose visibility cannot be read is refused, naming why.
# The visibility read happens only after a hit, so a clean command costs no
# network call.
#
# FAILURES. No list means nothing is checked, exactly as before the list
# existed. An unreadable payload passes, because it cannot be known to publish
# anything. Once a command is known to publish, any failure inside the check
# refuses it.
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys

GUARD = pathlib.Path(__file__).resolve().parent / "fm-leak-guard.sh"
FILE_CAP = 1 << 20

REPO_FLAG = r"(?:(?:-R|--repo)(?:=|\s+)\S+\s+)?"
PR_TEXT = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s+" + REPO_FLAG + r"(?:pr|issue)\s+" + REPO_FLAG
                     + r"(?:create|edit|comment|review|close|merge)\b")
API = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s+api\b")
API_SENDS = re.compile(r"(?:^|\s)(?:-f|-F|--field|--raw-field|--input)(?:=|\s|$)"
                       r"|(?:-X|--method)(?:=|\s*)(?:POST|PATCH|PUT)\b", re.I)
PIPELINE = re.compile(r"(?:^|[\s/;&|(`])no-mistakes\s+axi\s+(?:run|respond)\b")
API_REPO = re.compile(r"(?:^|[\s'\"/])repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)")
REMOTE = re.compile(r"^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/]+(.+?)(?:\.git)?/?$")


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def opts(argv, names):
    found = {}
    i = 0
    while i < len(argv):
        name = argv[i][2:] if argv[i].startswith("--") else None
        if name not in names or i + 1 >= len(argv):
            raise SystemExit("usage: fm-pr-text-guard.py hook --home DIR (see the header)")
        found[name] = argv[i + 1]
        i += 2
    missing = [n for n in names if n not in found]
    if missing:
        raise SystemExit("fm-pr-text-guard.py: missing --%s" % missing[0])
    return found


def publishes(command):
    if PR_TEXT.search(command) or PIPELINE.search(command):
        return True
    return bool(API.search(command) and API_SENDS.search(command))


def tokens(command):
    try:
        return shlex.split(command, posix=True)
    except ValueError:
        return []


def named_files(words, cwd):
    """Every existing file the command names as a body or input."""
    found = []
    for i, word in enumerate(words):
        if word in ("--body-file", "-F", "--input") and i + 1 < len(words):
            candidate = words[i + 1]
        elif word.startswith(("--body-file=", "--input=")):
            candidate = word.split("=", 1)[1]
        elif "=@" in word:
            candidate = word.split("=@", 1)[1]
        else:
            continue
        if candidate in ("", "-"):
            continue
        path = pathlib.Path(os.path.expanduser(candidate))
        if not path.is_absolute():
            path = pathlib.Path(cwd) / path
        if path.is_file():
            found.append(path)
    return found


def listed_words(text, home):
    """The listed words in text, by bin/fm-leak-guard.sh --text."""
    env = dict(os.environ, FM_HOME=home)
    result = subprocess.run(["bash", str(GUARD), "--text", "-"], input=text.encode("utf-8", "replace"),
                            capture_output=True, env=env, timeout=20)
    if result.returncode == 0:
        return []
    prefix = "LEAK_HIT: private-word: stdin: "
    words = [line[len(prefix):] for line in result.stderr.decode("utf-8", "replace").splitlines()
             if line.startswith(prefix)]
    if result.returncode != 1 or not words:
        raise RuntimeError("the word check exited %d: %s" % (
            result.returncode, result.stderr.decode("utf-8", "replace").strip()[:300]))
    return words


def flag_value(words, short, long):
    for i, word in enumerate(words):
        if word in (short, long) and i + 1 < len(words):
            return words[i + 1]
        if word.startswith(long + "="):
            return word.split("=", 1)[1]
    return None


def target(command, words, cwd):
    """(repository for gh repo view or None for gh's default, whether to check it at all)."""
    if PIPELINE.search(command) and not PR_TEXT.search(command) and not API.search(command):
        url = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        m = REMOTE.match(url)
        if not m or m.group(1).lower() != "github.com":
            return None, False
        return m.group(2), True
    repo = flag_value(words, "-R", "--repo")
    if not repo:
        m = API_REPO.search(command)
        repo = m.group(1) if m else None
    return repo, True


def visibility(repo, cwd):
    """'private', 'public', or the reason it could not be read."""
    args = ["gh", "repo", "view"] + ([repo] if repo else []) + ["--json", "isPrivate", "--jq", ".isPrivate"]
    try:
        result = subprocess.run(args, capture_output=True, text=True, cwd=cwd, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        return "gh could not run (%s)" % type(e).__name__
    answer = result.stdout.strip()
    if result.returncode == 0 and answer in ("true", "false"):
        return "private" if answer == "true" else "public"
    return "gh repo view failed: %s" % (result.stderr.strip().splitlines() or ["no output"])[-1][:200]


def check_hint(home):
    return "FM_HOME=%s %s --text <file>" % (shlex.quote(home), shlex.quote(str(GUARD)))


def cmd_hook(argv):
    o = opts(argv, ("home",))
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") != "Bash":
            return 0
        tool_input = payload.get("tool_input")
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        if not isinstance(command, str) or not publishes(command):
            return 0
        cwd = payload.get("cwd") or os.getcwd()
    except Exception:  # an unreadable payload cannot be known to publish anything
        return 0
    try:
        words = tokens(command)
        text = command
        for path in named_files(words, cwd):
            with open(path, "rb") as f:
                text += "\n" + f.read(FILE_CAP).decode("utf-8", "replace")
        hits = listed_words(text, o["home"])
        if not hits:
            return 0
        repo, checked = target(command, words, cwd)
        if not checked:
            return 0
        named = ", ".join('"%s"' % w for w in hits)
        where = repo or "the repository this command reaches"
        seen = visibility(repo, cwd)
        if seen == "private":
            return 0
        if seen == "public":
            deny("Starship refused this command: the text it would publish to %s, a public repository, contains %s,"
                 " from this home's private word list. Personal and work details never go into a public"
                 " repository's PR titles, descriptions, comments or pipeline intent."
                 " Rewrite the text without %s and run it again; check a draft first with: %s"
                 % (where, named, "it" if len(hits) == 1 else "them", check_hint(o["home"])))
            return 0
        deny("Starship refused this command: the text it would publish to %s contains %s, from this home's private"
             " word list, and Starship could not confirm the repository is private (%s)."
             " Rewrite the text without those words; if the repository is private and this keeps happening,"
             " append a blocked: status line naming this and stop." % (where, named, seen))
    except Exception as e:  # a command known to publish never passes a check that failed
        deny("Starship refused this command because its PR text check failed (%s: %s)."
             " Do not route around it; append a blocked: status line naming this error and stop."
             % (type(e).__name__, str(e)[:300]))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] != "hook":
        print("usage: fm-pr-text-guard.py hook --home DIR (see the header)", file=sys.stderr)
        return 2
    return cmd_hook(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
