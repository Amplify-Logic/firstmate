#!/usr/bin/env python3
"""fm-voice-idea.py - file an idea spoken into the glasses on its Artevo song.

The journey this owns, firstmate side (docs/voice-ideas.md):

  The captain says "What a Life, bridge idea" into the glasses and hums.
  VoiceLoop posts that recording to the glasses mailbox with its request id.
  This script recognises it as an idea for a song, holds the audio under that
  id as its capture id, hands it to Artevo through the Artevo Inbox, runs
  Artevo's own import, and speaks Artevo's receipt: "Filed to What a Life."
  When Artevo cannot be reached it says "Saved, waiting for the desk." and
  keeps the capture until it can, then announces the receipt.

What counts as an idea: the words lead with a song title from Artevo's song
list (songs.json in the Artevo Inbox, else the last copy this script kept),
and the idea word follows within four words, not led by a question word
("What a Life, bridge idea" files; "What a Life, any ideas what to do next?"
does not). A leading "file this idea" makes the idea word unnecessary. The
title match uses the same normalisation Artevo's importer uses, and the song
goes to Artevo as the captain's own word (sidecar `how: named`), so Artevo
files it as fact rather than as a suggestion. Artevo alone decides the filing;
the spoken receipt reads Artevo's report and never assumes it.

One capture per recording: the capture id is the mailbox request id, which
VoiceLoop keeps across its retries, so a re-send of one request is the same
held capture. The same audio under a different request id is recognised by
its content hash, answered from the first capture, and never handed over a
second time; Artevo's importer also dedupes by content hash.

Boundaries:
  - It writes into the Artevo Inbox only (a sidecar, then the audio, each via a
    hidden temporary name), and runs Artevo's own `captures import` command.
    It never edits the Artevo checkout, the career root, or any file it did
    not write, and never deletes anything from the inbox.
  - It reads the glasses mailbox database read-only. Answers go through the
    glasses project's own answer CLI and later lines through its announce
    CLI, both at absolute paths, so the mailbox keeps one writer contract.
  - Spoken lines are short outcomes and never carry an id or a path.
  - The phone side (holding a recording while the Mac is asleep, and saying so)
    belongs to VoiceLoop in the glasses-voice project, not to this script.

Usage:
  fm-voice-idea.py match [--songs PATH] TEXT...
      Say whether TEXT is an idea for a song. Prints one JSON object.
      Exit 0 an idea, 3 not an idea, 1 no song list to match against.
  fm-voice-idea.py take REQUEST_ID [--song TITLE] [--text TEXT]
      Hold that mailbox question as an idea capture, hand it to Artevo when
      it can, and answer it with the receipt or the waiting line. --song
      names the song when the words alone were not recognised (the caller
      heard the song); --text replaces the mailbox transcript. Idempotent.
      Exit 0 held or filed, 3 not an idea, 1 error.
  fm-voice-idea.py deliver
      Try every held capture again and speak each new receipt.
  fm-voice-idea.py check
      The watcher check body: take every pending mailbox question that is an
      idea, then deliver. Prints one line only when firstmate should look:
      a capture that first failed to reach Artevo, could not be filed at all,
      or whose receipt could not be spoken. Silent otherwise, and bounded by
      FM_CHECK_TIMEOUT.
  fm-voice-idea.py status [--json]
      One line per capture: filed, waiting for the desk and why, not filed,
      failed, or a duplicate.
  fm-voice-idea.py arm | disarm
      Write and register, or retire, the watcher check
      state/fm-glasses-idea.check.sh (bin/fm-check-register.sh). The id sorts
      before other glasses checks, so an idea is taken before a generic
      "question waiting" wake can fire for it in the same sweep.

Environment (all optional; defaults are this home's glasses and Artevo setup):
  FM_VOICE_IDEA_MAILBOX_DB      mailbox database (data/glasses-voice-runtime/mailbox.db)
  FM_VOICE_IDEA_TOKEN_FILE      relay token file (relay-token beside the database)
  FM_VOICE_IDEA_ANSWER          glasses answer CLI (data/glasses-voice-runtime/.venv/bin/glasses-voice-answer)
  FM_VOICE_IDEA_ANNOUNCE        glasses announce CLI (projects/glasses-voice/bin/announce)
  FM_VOICE_IDEA_TARTEVO         Artevo command (projects/artevo-workspace/bin/tartevo)
  FM_VOICE_IDEA_IMPORT_TIMEOUT  seconds allowed for one Artevo import (15)
  FM_VOICE_IDEA_SPEAK_TIMEOUT   seconds allowed for one answer or announcement (15)
  TARTEVO_INBOX                 the Artevo Inbox, read the way Artevo reads it
                                (else ~/Library/Mobile Documents/com~apple~CloudDocs/Artevo Inbox)
  TARTEVO_CAREER_ROOT           passed through to Artevo's import untouched
  `arm` bakes FM_HOME, and every variable above that is set, into the check.

State (private, per home, 0700): data/voice-ideas/
  songs.json                  last Artevo song list read, used when the inbox is away
  by-hash/<sha256>            the first capture id that held these bytes
  captures/<capture id>/      capture.json, the audio, then as they happen:
    delivered.json            the inbox file name this capture was handed over as
    outcome.json              the receipt, a duplicate verdict, or a failure (final)
    attempt.json              the last reason the desk could not be reached
    answered, answer-lost     whether the mailbox question got this script's answer
    said-final                the final line reached the glasses
    woke-*                    a wake line already printed for that problem

Exit codes: 0 ok, 1 error, 2 usage, 3 not an idea.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

SCHEMA = "fm-voice-idea-v1"
CHECK_ID = "fm-glasses-idea"

HELD_LINE = "Saved, waiting for the desk."
DUPLICATE_HELD_LINE = "Already saved, waiting for the desk."
NO_AUDIO_LINE = "I couldn't file that idea: no recording came with it."
BAD_FORMAT_LINE = "I couldn't file that idea: Artevo can't take that recording format."

EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_NOT_IDEA = 0, 1, 2, 3

# Artevo's importer reads these audio suffixes (core/capture_inbox.py).
ARTEVO_SUFFIXES = (".m4a", ".wav", ".mp3", ".aac", ".caf", ".aiff", ".aif", ".flac")
MEDIA_EXT = {
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/wave": ".wav",
    "audio/vnd.wave": ".wav",
    "audio/mp4": ".m4a",
    "audio/m4a": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/flac": ".flac",
    "audio/x-flac": ".flac",
    "audio/aiff": ".aiff",
    "audio/x-aiff": ".aiff",
    "audio/x-caf": ".caf",
}

LEAD_INS = (("file", "this", "idea"), ("file", "an", "idea"), ("file", "the", "idea"), ("file", "this"))
LEAD_PREPOSITIONS = {"for", "to", "on", "under", "in", "into"}
IDEA_WORDS = {"idea", "ideas"}
IDEA_WINDOW = 4
QUESTION_WORDS = {
    "any", "what", "whats", "how", "where", "when", "why", "who", "which", "do", "does", "did",
    "is", "are", "was", "were", "can", "could", "should", "would", "will", "shall", "have",
    "has", "tell",
}
NOTE_MAX_CHARS = 160
FILED_KINDS = {"picked", "named"}
RECEIPT_STATUSES = {"imported", "duplicate", "already_imported"}

SCRIPT = Path(__file__).resolve()
BIN = SCRIPT.parent


# The reason a step was not tried because this pass ran out of time. It is
# never recorded or woken on: the next pass simply tries again.
NO_TIME = "no time left in this pass"


class Failure(Exception):
    """An operational error reported on stderr with exit 1."""


# -- paths -----------------------------------------------------------------------


class Paths:
    def __init__(self, env: dict) -> None:
        home = env.get("FM_HOME") or env.get("FM_ROOT_OVERRIDE") or str(BIN.parent)
        self.home = Path(home).expanduser()
        self.state = Path(env.get("FM_STATE_OVERRIDE") or self.home / "state")
        self.data = Path(env.get("FM_DATA_OVERRIDE") or self.home / "data")
        projects = Path(env.get("FM_PROJECTS_OVERRIDE") or self.home / "projects")
        runtime = self.data / "glasses-voice-runtime"
        self.spool = self.data / "voice-ideas"
        self.captures = self.spool / "captures"
        self.by_hash = self.spool / "by-hash"
        self.mailbox_db = Path(env.get("FM_VOICE_IDEA_MAILBOX_DB") or runtime / "mailbox.db")
        self.token_file = Path(env.get("FM_VOICE_IDEA_TOKEN_FILE") or self.mailbox_db.parent / "relay-token")
        self.answer_cli = Path(
            env.get("FM_VOICE_IDEA_ANSWER") or runtime / ".venv" / "bin" / "glasses-voice-answer"
        )
        self.announce_cli = Path(
            env.get("FM_VOICE_IDEA_ANNOUNCE") or projects / "glasses-voice" / "bin" / "announce"
        )
        self.tartevo = Path(
            env.get("FM_VOICE_IDEA_TARTEVO") or projects / "artevo-workspace" / "bin" / "tartevo"
        )
        inbox = (env.get("TARTEVO_INBOX") or "").strip()
        if inbox:
            self.inbox = Path(inbox).expanduser()
        else:
            self.inbox = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "Artevo Inbox"
        self.import_timeout = _seconds(env.get("FM_VOICE_IDEA_IMPORT_TIMEOUT"), 15)
        self.speak_timeout = _seconds(env.get("FM_VOICE_IDEA_SPEAK_TIMEOUT"), 15)


def _seconds(raw: str | None, default: int) -> int:
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


class Context:
    def __init__(self, paths: Paths, budget: float) -> None:
        self.paths = paths
        self.deadline = time.monotonic() + budget
        self._songs: list | None = None
        self._songs_loaded = False

    def remaining(self) -> float:
        return self.deadline - time.monotonic()

    def timeout(self, wanted: int) -> float | None:
        left = self.remaining() - 1
        if left < 2:
            return None
        return min(float(wanted), left)

    def songs(self) -> list | None:
        if not self._songs_loaded:
            self._songs = load_songs(self.paths, cache=True)
            self._songs_loaded = True
        return self._songs


# -- small file helpers --------------------------------------------------------


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def write_atomic(path: Path, text: str, mode: int = 0o600) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_once(path: Path, text: str) -> bool:
    """Publish ``text`` at ``path`` only if nothing is there yet."""
    try:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True


def read_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def dump(value: dict) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


class SpoolLock:
    """One writer at a time: the watcher check, a manual take, or a deliver."""

    def __init__(self, paths: Paths, wait: bool) -> None:
        self.paths = paths
        self.wait = wait
        self.handle = None

    def __enter__(self) -> "SpoolLock | None":
        ensure_private_dir(self.paths.spool)
        self.handle = open(self.paths.spool / ".lock", "a", encoding="utf-8")
        deadline = time.monotonic() + (30 if self.wait else 0)
        while True:
            try:
                fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.handle.close()
                    self.handle = None
                    return None
                time.sleep(0.2)

    def __exit__(self, *exc: object) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle, fcntl.LOCK_UN)
            self.handle.close()


# -- songs and recognition -----------------------------------------------------


def normalize(text: object) -> str:
    """Artevo's title normalisation: case, accents and punctuation removed."""
    raw = unicodedata.normalize("NFKD", str(text or ""))
    raw = "".join(ch for ch in raw if not unicodedata.combining(ch))
    raw = raw.casefold().replace("&", " and ")
    return " ".join(re.sub(r"[^0-9a-z]+", " ", raw).split())


def parse_songs(doc: object) -> list:
    if not isinstance(doc, dict) or doc.get("schema_version") != 1:
        raise ValueError("not an Artevo songs.json this script knows (schema_version 1)")
    rows = doc.get("songs")
    if not isinstance(rows, list):
        raise ValueError("songs.json has no songs list")
    songs = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        title = str(row.get("title") or "").strip()
        if not title:
            continue
        songs.append({"id": str(row.get("id") or "") or None, "title": title, "slug": str(row.get("slug") or "")})
    return songs


def load_songs(paths: Paths, cache: bool) -> list | None:
    """Artevo's song list from the inbox, else the last copy kept here."""
    live = paths.inbox / "songs.json"
    kept = paths.spool / "songs.json"
    try:
        raw = live.read_text(encoding="utf-8")
        songs = parse_songs(json.loads(raw))
    except (OSError, ValueError):
        songs = None
    if songs is not None:
        if cache:
            try:
                ensure_private_dir(paths.spool)
                if not kept.is_file() or kept.read_text(encoding="utf-8") != raw:
                    write_atomic(kept, raw)
            except OSError:
                pass
        return songs
    try:
        return parse_songs(json.loads(kept.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return None


def _leading_song(words: list, songs: list) -> tuple[dict | None, int, bool]:
    """The song whose title leads ``words``: longest title wins, a tie is ambiguous."""
    best_len = 0
    best: dict = {}
    for song in songs:
        for key in {normalize(song["title"]), normalize(song["slug"])}:
            key_words = key.split()
            if not key_words or words[: len(key_words)] != key_words:
                continue
            ident = song["id"] or song["title"]
            if len(key_words) > best_len:
                best_len, best = len(key_words), {ident: song}
            elif len(key_words) == best_len:
                best[ident] = song
    if not best:
        return None, 0, False
    return next(iter(best.values())), best_len, len(best) > 1


def _note(words: list) -> str | None:
    note = " ".join(words)[:NOTE_MAX_CHARS].strip()
    return note or None


def _strip_lead_in(words: list) -> tuple[list, bool]:
    """Drop a leading "file this idea (for)", saying whether there was one."""
    for lead in LEAD_INS:
        if tuple(words[: len(lead)]) == lead:
            words = words[len(lead):]
            if words and words[0] in LEAD_PREPOSITIONS:
                words = words[1:]
            return words, True
    return words, False


def recognise(text: str, songs: list) -> dict:
    """Is ``text`` an idea for a song? Song name first, then the idea."""
    words, explicit = _strip_lead_in(normalize(text).split())
    song, length, ambiguous = _leading_song(words, songs)
    if song is None:
        return {"idea": False, "reason": "the words do not start with a song name"}
    rest = words[length:]
    if not explicit:
        if not rest or rest[0] in QUESTION_WORDS:
            return {"idea": False, "reason": "the words after the song name are not an idea"}
        if not any(word in IDEA_WORDS for word in rest[:IDEA_WINDOW]):
            return {"idea": False, "reason": "no idea word follows the song name"}
    return {
        "idea": True,
        "song": song["title"],
        "song_id": None if ambiguous else song["id"],
        "ambiguous": ambiguous,
        "note": _note(rest),
        "explicit": explicit,
    }


def recognise_named(song_text: str, text: str, songs: list | None) -> dict:
    """The caller heard the song: resolve it against the list when there is one."""
    said = normalize(song_text).split()
    if not said:
        raise Failure("--song is empty")
    song, length, ambiguous = _leading_song(said, songs or [])
    words, _ = _strip_lead_in(normalize(text).split())
    if song is not None and length == len(said):
        lead, lead_length, _ = _leading_song(words, [song])
        rest = words[lead_length:] if lead is not None else words
        return {
            "idea": True, "song": song["title"], "song_id": None if ambiguous else song["id"],
            "ambiguous": ambiguous, "note": _note(rest), "explicit": True,
        }
    # Not in the list: it goes to Artevo as said, and Artevo decides.
    rest = words[len(said):] if words[: len(said)] == said else words
    return {
        "idea": True, "song": song_text.strip(), "song_id": None, "ambiguous": False,
        "note": _note(rest), "explicit": True,
    }


# -- the mailbox (read-only) ---------------------------------------------------


def open_mailbox(paths: Paths) -> sqlite3.Connection:
    db = paths.mailbox_db
    if not db.is_file():
        raise Failure(f"no glasses mailbox database at {db}")
    conn = sqlite3.connect(f"file:{quote(str(db))}?mode=ro", uri=True, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def _columns(conn: sqlite3.Connection) -> set:
    return {row["name"] for row in conn.execute("PRAGMA table_info(requests)")}


def question_row(conn: sqlite3.Connection, request_id: str) -> dict | None:
    cache = ", transcript_cache" if "transcript_cache" in _columns(conn) else ""
    row = conn.execute(
        f"SELECT request_id, question_json, created_at, state, answer_json{cache} "
        "FROM requests WHERE request_id = ?",
        (request_id,),
    ).fetchone()
    return dict(row) if row is not None else None


def pending_request_ids(conn: sqlite3.Connection) -> list:
    rows = conn.execute(
        "SELECT request_id FROM requests WHERE state = 'pending' ORDER BY created_at, request_id"
    )
    return [str(row["request_id"]).lower() for row in rows]


def mailbox_state(paths: Paths, request_id: str) -> tuple[str | None, str | None]:
    """``(state, answer text)`` of a request, or ``(None, None)`` when unreadable."""
    try:
        conn = open_mailbox(paths)
    except (Failure, sqlite3.Error):
        return None, None
    try:
        row = question_row(conn, request_id)
    except sqlite3.Error:
        return None, None
    finally:
        conn.close()
    if row is None:
        return "missing", None
    answer = None
    try:
        parsed = json.loads(row.get("answer_json") or "null")
        if isinstance(parsed, dict):
            answer = parsed.get("text")
    except ValueError:
        pass
    return str(row.get("state") or ""), answer


def parse_question(row: dict) -> dict:
    try:
        question = json.loads(row.get("question_json") or "")
    except ValueError:
        question = None
    if not isinstance(question, dict):
        raise Failure("the mailbox question is not readable")
    transcript = str(row.get("transcript_cache") or question.get("transcript") or "").strip()
    audio = question.get("audio") if isinstance(question.get("audio"), dict) else None
    return {
        "created_at": str(question.get("created_at") or row.get("created_at") or ""),
        "state": str(row.get("state") or ""),
        "transcript": transcript,
        "audio": audio,
    }


# -- holding a capture ---------------------------------------------------------

REQUEST_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def capture_id(raw: str) -> str:
    ident = str(raw or "").strip().lower()
    if not REQUEST_ID_RE.match(ident):
        raise Failure(f"not a mailbox request id: {raw!r}")
    return ident


def audio_of(question: dict) -> tuple[bytes | None, str | None, str | None]:
    """``(bytes, extension, failure line)`` for the question's recording."""
    audio = question["audio"]
    if not audio or not audio.get("data_base64"):
        return None, None, NO_AUDIO_LINE
    try:
        data = base64.b64decode(str(audio["data_base64"]), validate=True)
    except (ValueError, TypeError):
        return None, None, NO_AUDIO_LINE
    if not data:
        return None, None, NO_AUDIO_LINE
    media = str(audio.get("media_type") or "").split(";", 1)[0].strip().lower()
    ext = MEDIA_EXT.get(media)
    if ext is None and media in ("", "application/octet-stream"):
        # Only an untyped recording is judged by its file name.
        suffix = Path(str(audio.get("filename") or "")).suffix.lower()
        ext = suffix if suffix in ARTEVO_SUFFIXES else None
    if ext is None:
        return data, None, BAD_FORMAT_LINE
    return data, ext, None


def claim_hash(paths: Paths, digest: str, ident: str) -> str | None:
    """The earlier capture that holds these bytes, or None when this one is first."""
    ensure_private_dir(paths.by_hash)
    marker = paths.by_hash / digest
    if write_once(marker, ident + "\n"):
        return None
    try:
        first = marker.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return None if first == ident else first


def hold(ctx: Context, ident: str, question: dict, idea: dict) -> None:
    paths = ctx.paths
    ensure_private_dir(paths.captures)
    target = paths.captures / ident
    if target.exists():
        return
    data, ext, failure = audio_of(question)
    meta = {
        "schema": SCHEMA,
        "capture_id": ident,
        "spoken_at": question["created_at"],
        "held_at": now_iso(),
        "song": idea["song"],
        "song_id": idea.get("song_id"),
        "ambiguous": bool(idea.get("ambiguous")),
        "note": idea.get("note"),
        "transcript": question["transcript"],
        "media_type": (question["audio"] or {}).get("media_type"),
    }
    if data is not None and ext is not None:
        digest = hashlib.sha256(data).hexdigest()
        meta.update(
            ext=ext,
            byte_size=len(data),
            content_hash=f"sha256:{digest}",
            duplicate_of=claim_hash(paths, digest, ident),
        )
    work = Path(tempfile.mkdtemp(prefix=f".{ident}.", dir=str(paths.captures)))
    try:
        if data is not None and ext is not None:
            (work / f"audio{ext}").write_bytes(data)
        (work / "capture.json").write_text(dump(meta), encoding="utf-8")
        if failure is not None:
            outcome = {"kind": "failed", "line": failure, "at": now_iso()}
            (work / "outcome.json").write_text(dump(outcome), encoding="utf-8")
        os.chmod(work, 0o700)
        os.rename(work, target)
    except OSError:
        shutil.rmtree(work, ignore_errors=True)
        if not target.exists():
            raise


def load_capture(paths: Paths, ident: str) -> dict | None:
    return read_json(paths.captures / ident / "capture.json")


def all_captures(paths: Paths) -> list:
    if not paths.captures.is_dir():
        return []
    rows = []
    for entry in paths.captures.iterdir():
        if entry.name.startswith(".") or not entry.is_dir():
            continue
        meta = read_json(entry / "capture.json")
        if meta is not None:
            rows.append(meta)
    rows.sort(key=lambda meta: (str(meta.get("spoken_at") or ""), str(meta.get("capture_id"))))
    return rows


# -- handing a capture to Artevo -------------------------------------------------


def inbox_base(meta: dict) -> str:
    """A name that leads with the song's title, so Artevo files it even without a sidecar."""
    title = re.sub(r"[^\w '&(),.!-]+", " ", str(meta.get("song") or "Idea"), flags=re.UNICODE)
    title = " ".join(title.split()).lstrip(".").strip()[:80] or "Idea"
    stamp = re.sub(r"[^0-9]", "", str(meta.get("spoken_at") or ""))[:14]
    stamp = f"{stamp[:8]} {stamp[8:14]}".strip() if stamp else "undated"
    return f"{title} - glasses idea - {stamp} - {meta['capture_id'][:8]}"


def sidecar_text(meta: dict) -> str:
    """The captain's own word on the song. Stable bytes, so a retry finds it already placed."""
    fields = {
        "song": meta.get("song"),
        "how": "named",
        "note": meta.get("note"),
        "recorded_by": "captain",
        "recorded_at": meta.get("spoken_at") or None,
        "sent_at": meta.get("held_at") or None,
    }
    return json.dumps({k: v for k, v in fields.items() if v}, indent=2, ensure_ascii=False) + "\n"


def place_in_inbox(inbox: Path, name: str, data: bytes) -> str | None:
    """Put ``data`` at ``inbox/name`` via a hidden temporary name. None when it is there."""
    target = inbox / name
    if target.exists():
        try:
            if target.read_bytes() == data:
                return None
        except OSError as exc:
            return f"the Artevo Inbox copy could not be read ({exc.strerror or exc})"
        return "a different file already has this recording's name in the Artevo Inbox"
    fd, tmp = tempfile.mkstemp(prefix=".fm-voice-idea.", suffix=".tmp", dir=str(inbox))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return f"the Artevo Inbox could not be written ({exc.strerror or exc})"
    return None


def run_import(ctx: Context) -> tuple[dict | None, str | None]:
    paths = ctx.paths
    timeout = ctx.timeout(paths.import_timeout)
    if timeout is None:
        return None, NO_TIME
    cmd = [str(paths.tartevo), "captures", "import", "--inbox", str(paths.inbox), "--json", "--no-lyrics"]
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "Artevo's import did not finish in time"
    except OSError as exc:
        return None, f"Artevo's import could not start ({exc.strerror or exc})"
    try:
        report = json.loads(done.stdout)
    except ValueError:
        report = None
    if not isinstance(report, dict):
        return None, f"Artevo's import gave no report (exit {done.returncode})"
    if report.get("error"):
        return None, f"Artevo's import refused: {report['error']}"
    return report, None


def deliver(ctx: Context, ident: str, meta: dict) -> tuple[dict | None, str | None]:
    """Hand one capture to Artevo. ``(outcome, None)`` or ``(None, why it waits)``."""
    paths = ctx.paths
    if not paths.inbox.is_dir():
        return None, "the Artevo Inbox folder is not on this Mac"
    if not os.access(paths.tartevo, os.X_OK):
        return None, f"Artevo's command is not at {paths.tartevo}"
    ext = str(meta.get("ext") or "")
    try:
        data = (paths.captures / ident / f"audio{ext}").read_bytes()
    except OSError as exc:
        return None, f"the held recording could not be read ({exc.strerror or exc})"
    if f"sha256:{hashlib.sha256(data).hexdigest()}" != meta.get("content_hash"):
        return None, "the held recording no longer matches its hash"
    base = inbox_base(meta)
    name = base + ext
    # The sidecar goes first, as the share-sheet shortcut does, so the import
    # that sees the audio already has the song. Its name carries this capture's
    # id, so one already there is this capture's own from an earlier pass.
    if not (paths.inbox / (base + ".artevo.json")).exists():
        problem = place_in_inbox(paths.inbox, base + ".artevo.json", sidecar_text(meta).encode("utf-8"))
        if problem is not None:
            return None, problem
    problem = place_in_inbox(paths.inbox, name, data)
    if problem is not None:
        return None, problem
    write_once(paths.captures / ident / "delivered.json", dump({"name": name, "at": now_iso()}))
    report, problem = run_import(ctx)
    if report is None:
        return None, problem
    items = report.get("items") if isinstance(report.get("items"), list) else []
    item = next((row for row in items if isinstance(row, dict) and row.get("path") == name), None)
    if item is None:
        return None, "Artevo's import did not list this recording"
    status = str(item.get("status") or "")
    if status not in RECEIPT_STATUSES:
        detail = str(item.get("detail") or "").strip()
        return None, f"Artevo reported {status or 'no status'}" + (f": {detail}" if detail else "")
    if item.get("content_hash") and item.get("content_hash") != meta.get("content_hash"):
        return None, "Artevo's receipt is for different bytes than this recording"
    filing = str(item.get("filing") or "")
    song_title = str(item.get("song_title") or "").strip()
    receipt = {
        "status": status,
        "artevo_capture_id": item.get("capture_id"),
        "filing": filing or None,
        "song_title": song_title or None,
        "suggested_song_title": item.get("suggested_song_title"),
        "asset_path": item.get("asset_path"),
        "inbox_name": name,
    }
    if filing in FILED_KINDS and song_title:
        return {"kind": "filed", "line": f"Filed to {song_title}.", "receipt": receipt, "at": now_iso()}, None
    line = f"Saved in Artevo, but not filed to {meta.get('song')}."
    return {"kind": "not_filed", "line": line, "receipt": receipt, "at": now_iso()}, None


# -- speaking --------------------------------------------------------------------


def _last_line(done: subprocess.CompletedProcess) -> str:
    lines = (done.stderr or done.stdout or "").strip().splitlines()
    return lines[-1] if lines else f"exit {done.returncode}"


def _speak_env(paths: Paths) -> dict | None:
    env = dict(os.environ)
    try:
        token = paths.token_file.read_text(encoding="utf-8").strip()
    except OSError:
        token = ""
    if not token:
        return None
    env["GLASSES_RELAY_TOKEN"] = token
    env["GLASSES_VOICE_DB"] = str(paths.mailbox_db)
    env["GLASSES_VOICE_RUNTIME"] = str(paths.mailbox_db.parent)
    return env


def answer(ctx: Context, ident: str, line: str) -> tuple[str, str]:
    """Answer the question: ``("ours" | "elsewhere" | "retry", why)``."""
    paths = ctx.paths
    state, text = mailbox_state(paths, ident)
    if state in ("answered", "missing"):
        return ("ours", "") if text == line else ("elsewhere", f"the question was {state} already")
    env = _speak_env(paths)
    if env is None:
        return "retry", f"no relay token at {paths.token_file}"
    timeout = ctx.timeout(paths.speak_timeout)
    if timeout is None:
        return "retry", NO_TIME
    cmd = [str(paths.answer_cli), ident, "--text", line, "--database", str(paths.mailbox_db)]
    try:
        done = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL
        )
        why = _last_line(done)
    except subprocess.TimeoutExpired:
        why = "the answer took too long"
    except OSError as exc:
        why = f"the answer could not start ({exc.strerror or exc})"
    # The mailbox, not the exit status, says whose answer landed: a text answer
    # is committed before its audio, so a slow synthesis can outlive the call.
    state, text = mailbox_state(paths, ident)
    if state in ("answered", "missing"):
        return ("ours", "") if text == line else ("elsewhere", f"the question was {state} by someone else")
    return "retry", why


def announce(ctx: Context, line: str) -> tuple[str, str]:
    """Speak a later line: ``("spoken" | "refused" | "retry", why)``."""
    paths = ctx.paths
    env = _speak_env(paths)
    if env is None:
        return "retry", f"no relay token at {paths.token_file}"
    timeout = ctx.timeout(paths.speak_timeout)
    if timeout is None:
        return "retry", NO_TIME
    try:
        done = subprocess.run(
            [str(paths.announce_cli), line],
            capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return "retry", "the announcement took too long"
    except OSError as exc:
        return "retry", f"the announcement could not start ({exc.strerror or exc})"
    why = _last_line(done)
    if done.returncode == 0:
        return "spoken", ""
    if done.returncode == 2:
        return "refused", why
    return "retry", why


# -- one capture, moved as far forward as it can go --------------------------------


def _marker(paths: Paths, ident: str, name: str) -> Path:
    return paths.captures / ident / name


def _wake_once(paths: Paths, ident: str, kind: str, line: str, wakes: list) -> None:
    if write_once(_marker(paths, ident, f"woke-{kind}"), line + "\n"):
        wakes.append(line)


def duplicate_outcome(paths: Paths, meta: dict) -> dict:
    first = str(meta.get("duplicate_of") or "")
    original = read_json(paths.captures / first / "outcome.json") if first else None
    if original and original.get("kind") == "filed":
        song = (original.get("receipt") or {}).get("song_title") or meta.get("song")
        line = f"Already filed to {song}."
    elif original is None:
        line = DUPLICATE_HELD_LINE
    else:
        line = str(original.get("line") or DUPLICATE_HELD_LINE)
    return {"kind": "duplicate", "duplicate_of": first, "line": line, "at": now_iso()}


def advance(ctx: Context, ident: str, wakes: list) -> dict:
    """Deliver if the capture still waits, then say what is true now, once."""
    paths = ctx.paths
    folder = paths.captures / ident
    meta = load_capture(paths, ident)
    if meta is None:
        raise Failure(f"no held capture {ident}")
    song = meta.get("song") or "that song"
    outcome = read_json(folder / "outcome.json")
    if outcome is None and meta.get("duplicate_of"):
        outcome = duplicate_outcome(paths, meta)
        write_once(folder / "outcome.json", dump(outcome))
    elif outcome is None:
        outcome, waiting = deliver(ctx, ident, meta)
        if outcome is not None:
            if not write_once(folder / "outcome.json", dump(outcome)):
                outcome = read_json(folder / "outcome.json")
        elif waiting == NO_TIME:
            # Not tried, so nothing is known yet: say nothing until a pass tries.
            return {"capture": meta, "outcome": None}
        else:
            write_atomic(folder / "attempt.json", dump({"at": now_iso(), "reason": waiting}))
            _wake_once(paths, ident, "waiting",
                       f"glasses idea for {song} is saved but waiting for the desk: {waiting}", wakes)
    elif outcome.get("kind") == "failed":
        _wake_once(paths, ident, "failed",
                   f"glasses idea for {song} could not be filed: {outcome.get('line')}", wakes)

    if (folder / "said-final").exists():
        return {"capture": meta, "outcome": outcome}
    final = outcome is not None
    line = str(outcome["line"]) if final else HELD_LINE
    answered = (folder / "answered").exists()
    lost = (folder / "answer-lost").exists()
    if not answered and not lost:
        verdict, why = answer(ctx, ident, line)
        if verdict == "ours":
            write_once(folder / "answered", line + "\n")
            if final:
                write_once(folder / "said-final", "answer\n")
            return {"capture": meta, "outcome": outcome}
        if verdict == "elsewhere":
            write_once(folder / "answer-lost", why + "\n")
        else:
            if why == NO_TIME:
                return {"capture": meta, "outcome": outcome}
            _wake_once(paths, ident, "answer",
                       f"glasses idea receipt for {song} could not be spoken: {why}", wakes)
            return {"capture": meta, "outcome": outcome}
    if final:
        verdict, why = announce(ctx, line)
        if verdict == "spoken":
            write_once(folder / "said-final", "announce\n")
        elif verdict == "refused":
            write_once(folder / "said-final", f"refused: {why}\n")
        elif why != NO_TIME:
            _wake_once(paths, ident, "announce",
                       f"glasses idea receipt for {song} could not be spoken: {why}", wakes)
    return {"capture": meta, "outcome": outcome}


def take(ctx: Context, ident: str, song: str | None, text: str | None, wakes: list) -> dict | None:
    """Hold one mailbox question as an idea and move it forward. None when not an idea."""
    paths = ctx.paths
    if not (paths.captures / ident).is_dir():
        conn = open_mailbox(paths)
        try:
            row = question_row(conn, ident)
        finally:
            conn.close()
        if row is None:
            raise Failure(f"no question {ident} in the glasses mailbox")
        question = parse_question(row)
        words = question["transcript"] if text is None else text
        if song:
            idea = recognise_named(song, words, ctx.songs())
        else:
            songs = ctx.songs()
            if songs is None:
                raise Failure("no Artevo song list to recognise a song name against")
            idea = recognise(words, songs)
            if not idea["idea"]:
                return None
        hold(ctx, ident, question, idea)
        if question["state"] == "answered":
            write_once(paths.captures / ident / "answer-lost", "answered before it was taken\n")
    return advance(ctx, ident, wakes)


# -- commands --------------------------------------------------------------------


def cmd_match(args: argparse.Namespace, paths: Paths) -> int:
    text = " ".join(args.text)
    if args.songs:
        try:
            songs = parse_songs(json.loads(Path(args.songs).read_text(encoding="utf-8")))
        except (OSError, ValueError) as exc:
            print(json.dumps({"idea": False, "reason": f"song list unreadable: {exc}"}))
            return EXIT_ERROR
    else:
        songs = load_songs(paths, cache=False)
        if songs is None:
            print(json.dumps({"idea": False, "reason": "no Artevo song list"}))
            return EXIT_ERROR
    verdict = recognise(text, songs)
    print(json.dumps(verdict, ensure_ascii=False, sort_keys=True))
    return EXIT_OK if verdict["idea"] else EXIT_NOT_IDEA


def _report(result: dict) -> str:
    meta, outcome = result["capture"], result["outcome"]
    song = meta.get("song")
    if outcome is None:
        return f"held: {song}: {HELD_LINE}"
    return f"{outcome.get('kind')}: {song}: {outcome.get('line')}"


def cmd_take(args: argparse.Namespace, paths: Paths) -> int:
    ident = capture_id(args.request_id)
    ctx = Context(paths, budget=120)
    wakes: list = []
    with SpoolLock(paths, wait=True) as lock:
        if lock is None:
            raise Failure("another fm-voice-idea run holds the spool lock")
        result = take(ctx, ident, args.song, args.text, wakes)
    if result is None:
        print("not an idea: the words do not start with a song name followed by an idea")
        return EXIT_NOT_IDEA
    print(_report(result))
    for line in wakes:
        print(line, file=sys.stderr)
    return EXIT_OK


def _waiting(paths: Paths) -> list:
    return [
        meta["capture_id"]
        for meta in all_captures(paths)
        if not (paths.captures / meta["capture_id"] / "said-final").exists()
    ]


def cmd_deliver(_args: argparse.Namespace, paths: Paths) -> int:
    ctx = Context(paths, budget=120)
    wakes: list = []
    with SpoolLock(paths, wait=True) as lock:
        if lock is None:
            raise Failure("another fm-voice-idea run holds the spool lock")
        for ident in _waiting(paths):
            if ctx.remaining() < 3:
                break
            print(_report(advance(ctx, ident, wakes)))
    for line in wakes:
        print(line, file=sys.stderr)
    return EXIT_OK


def cmd_check(_args: argparse.Namespace, paths: Paths) -> int:
    budget = _seconds(os.environ.get("FM_CHECK_TIMEOUT"), 30) - 4
    ctx = Context(paths, budget=max(budget, 3))
    wakes: list = []
    try:
        with SpoolLock(paths, wait=False) as lock:
            if lock is None:
                return EXIT_OK
            pending: list = []
            if paths.mailbox_db.is_file():
                try:
                    conn = open_mailbox(paths)
                    try:
                        pending = pending_request_ids(conn)
                    finally:
                        conn.close()
                except (Failure, sqlite3.Error):
                    pending = []
            moved = set()
            for ident in pending:
                if ctx.remaining() < 3:
                    break
                if not REQUEST_ID_RE.match(ident):
                    continue
                try:
                    if take(ctx, ident, None, None, wakes) is not None:
                        moved.add(ident)
                except (Failure, sqlite3.Error):
                    continue
            for ident in _waiting(paths):
                if ctx.remaining() < 3:
                    break
                if ident in moved:
                    continue
                try:
                    advance(ctx, ident, wakes)
                except Failure:
                    continue
    except Exception as exc:  # the watcher discards stderr, so a crash must still say so
        wakes.append(f"glasses ideas could not be checked: {exc}")
    if wakes:
        extra = f" (and {len(wakes) - 1} more)" if len(wakes) > 1 else ""
        print(f"{wakes[0]}{extra}; see bin/fm-voice-idea.py status")
    return EXIT_OK


def _status_row(paths: Paths, meta: dict) -> dict:
    folder = paths.captures / meta["capture_id"]
    outcome = read_json(folder / "outcome.json")
    attempt = read_json(folder / "attempt.json")
    if outcome is None:
        state, detail = "waiting", (attempt or {}).get("reason") or "not tried yet"
    else:
        state, detail = str(outcome.get("kind")), str(outcome.get("line") or "")
    return {
        "capture_id": meta["capture_id"],
        "spoken_at": meta.get("spoken_at"),
        "song": meta.get("song"),
        "note": meta.get("note"),
        "state": state,
        "detail": detail,
        "spoken": (folder / "said-final").exists(),
    }


def cmd_status(args: argparse.Namespace, paths: Paths) -> int:
    rows = [_status_row(paths, meta) for meta in all_captures(paths)]
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return EXIT_OK
    if not rows:
        print("no glasses ideas held")
        return EXIT_OK
    for row in rows:
        label = "waiting for the desk" if row["state"] == "waiting" else row["state"]
        spoken = "" if row["spoken"] or row["state"] == "waiting" else " (receipt not spoken yet)"
        print(f"{row['spoken_at']}  {row['song']}  {label}: {row['detail']}{spoken}  [{row['capture_id']}]")
    return EXIT_OK


BAKED_ENV = (
    "FM_VOICE_IDEA_MAILBOX_DB",
    "FM_VOICE_IDEA_TOKEN_FILE",
    "FM_VOICE_IDEA_ANSWER",
    "FM_VOICE_IDEA_ANNOUNCE",
    "FM_VOICE_IDEA_TARTEVO",
    "FM_VOICE_IDEA_IMPORT_TIMEOUT",
    "FM_VOICE_IDEA_SPEAK_TIMEOUT",
    "FM_DATA_OVERRIDE",
    "FM_PROJECTS_OVERRIDE",
    "TARTEVO_INBOX",
    "TARTEVO_CAREER_ROOT",
    "TARTEVO_ROOT",
)


def check_shim(paths: Paths) -> str:
    assignments = [f"FM_HOME={shlex.quote(str(paths.home.resolve()))}"]
    for name in BAKED_ENV:
        value = os.environ.get(name)
        if value:
            assignments.append(f"{name}={shlex.quote(value)}")
    command = " ".join(
        ["exec", "/usr/bin/env", *assignments, shlex.quote(sys.executable), shlex.quote(str(SCRIPT)), "check"]
    )
    return (
        "#!/bin/bash\n"
        "# Generated by bin/fm-voice-idea.py arm; retire it with bin/fm-voice-idea.py disarm.\n"
        "# Files ideas spoken into the glasses on their Artevo song (docs/voice-ideas.md).\n"
        f"{command}\n"
    )


def _register_env(paths: Paths) -> dict:
    env = dict(os.environ)
    env["FM_HOME"] = str(paths.home)
    return env


def cmd_arm(_args: argparse.Namespace, paths: Paths) -> int:
    if not paths.state.is_dir():
        raise Failure(f"no state directory at {paths.state}")
    check = paths.state / f"{CHECK_ID}.check.sh"
    fd, tmp = tempfile.mkstemp(prefix=f".{CHECK_ID}.", dir=str(paths.state))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(check_shim(paths))
        if subprocess.run(["bash", "-n", tmp], capture_output=True).returncode != 0:
            raise Failure("the generated check is not valid shell")
        os.chmod(tmp, 0o700)
        os.replace(tmp, check)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    done = subprocess.run(
        [str(BIN / "fm-check-register.sh"), CHECK_ID], capture_output=True, text=True, env=_register_env(paths)
    )
    if done.returncode != 0:
        subprocess.run([str(BIN / "fm-check-unregister.sh"), CHECK_ID], capture_output=True, env=_register_env(paths))
        raise Failure(f"could not register the check: {(done.stderr or done.stdout).strip()}")
    print(f"armed: state/{CHECK_ID}.check.sh")
    return EXIT_OK


def cmd_disarm(_args: argparse.Namespace, paths: Paths) -> int:
    done = subprocess.run(
        [str(BIN / "fm-check-unregister.sh"), CHECK_ID], capture_output=True, text=True, env=_register_env(paths)
    )
    if done.returncode != 0:
        raise Failure(f"could not retire the check: {(done.stderr or done.stdout).strip()}")
    print(f"disarmed: state/{CHECK_ID}.check.sh (held ideas are kept in data/voice-ideas)")
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-voice-idea.py",
        description="File an idea spoken into the glasses on its Artevo song (see this script's header).",
    )
    sub = parser.add_subparsers(dest="cmd")
    match = sub.add_parser("match", help="Say whether words are an idea for a song")
    match.add_argument("--songs", help="An Artevo songs.json to match against")
    match.add_argument("text", nargs="+")
    take_p = sub.add_parser("take", help="Hold one mailbox question as an idea and file it")
    take_p.add_argument("request_id")
    take_p.add_argument("--song", help="The song, when the caller heard it and the words were not recognised")
    take_p.add_argument("--text", help="Words to use instead of the mailbox transcript")
    sub.add_parser("deliver", help="Try every held idea again and speak new receipts")
    sub.add_parser("check", help="Watcher check: take pending ideas, deliver, wake only on a problem")
    status = sub.add_parser("status", help="One line per held idea")
    status.add_argument("--json", action="store_true")
    sub.add_parser("arm", help=f"Write and register state/{CHECK_ID}.check.sh")
    sub.add_parser("disarm", help=f"Retire state/{CHECK_ID}.check.sh")
    return parser


COMMANDS = {
    "match": cmd_match,
    "take": cmd_take,
    "deliver": cmd_deliver,
    "check": cmd_check,
    "status": cmd_status,
    "arm": cmd_arm,
    "disarm": cmd_disarm,
}


def main(argv: list | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.cmd:
        parser.print_help(sys.stderr)
        return EXIT_USAGE
    paths = Paths(dict(os.environ))
    try:
        return COMMANDS[args.cmd](args, paths)
    except Failure as exc:
        print(f"fm-voice-idea: {exc}", file=sys.stderr)
        return EXIT_ERROR
    except sqlite3.Error as exc:
        print(f"fm-voice-idea: the glasses mailbox could not be read: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
