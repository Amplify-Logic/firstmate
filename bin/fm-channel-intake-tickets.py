#!/usr/bin/env python3
"""Private open-tickets snapshot writer for fm-channel-intake.sh; that script's header owns the contract."""
import json
import os
from pathlib import Path
import re
import sys
import tempfile

FIELDS = ('id', 'subject', 'stage', 'last_in', 'last_out', 'link')


class Refusal(Exception):
    pass


def text(ticket, key, n, required=True):
    value = ticket.get(key)
    if not isinstance(value, str):
        raise Refusal(f'ticket {n}: {key} must be a string')
    value = ' '.join(value.split())
    if required and not value:
        raise Refusal(f'ticket {n}: {key} must not be empty')
    return value


def ticket_of(ticket, n):
    if not isinstance(ticket, dict):
        raise Refusal(f'ticket {n}: must be an object')
    unknown = sorted(set(ticket) - set(FIELDS))
    if unknown:
        raise Refusal(f'ticket {n}: unknown field {unknown[0]}')
    missing = [k for k in FIELDS if k not in ticket]
    if missing:
        raise Refusal(f'ticket {n}: missing field {missing[0]}')
    rec = {k: text(ticket, k, n, required=k not in ('subject', 'last_in', 'last_out')) for k in FIELDS}
    if not re.fullmatch(r'[0-9]+', rec['id']):
        raise Refusal(f'ticket {n}: id must be the numeric HubSpot ticket id')
    if not re.match(r'^https://', rec['link']):
        raise Refusal(f'ticket {rec["id"]}: link must be an https:// URL')
    if rec['stage'].casefold() == 'closed':
        raise Refusal(f'ticket {rec["id"]}: stage is Closed; the snapshot holds only tickets that are not closed')
    return rec


def main():
    out, owner, read_at, source = sys.argv[1:]
    raw = sys.stdin.read() if source == '-' else Path(source).read_text()
    try:
        doc = json.loads(raw)
    except ValueError as err:
        raise Refusal(f'input is not JSON: {err}')
    if not isinstance(doc, list):
        raise Refusal('input must be a JSON array of tickets')
    tickets = [ticket_of(t, n) for n, t in enumerate(doc, 1)]
    seen = set()
    for t in tickets:
        if t['id'] in seen:
            raise Refusal(f'ticket {t["id"]} appears twice')
        seen.add(t['id'])
    body = json.dumps({'version': 1, 'read_at': int(read_at), 'owner': owner, 'tickets': tickets},
                      indent=1, ensure_ascii=False) + '\n'
    parent = Path(out).parent
    parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix='.tickets.')
    try:
        with os.fdopen(fd, 'w') as fh:
            fh.write(body)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
    except BaseException:
        os.unlink(tmp)
        raise
    print(f'tickets: wrote {len(tickets)} open tickets for {owner} read at {read_at} to {out}')


try:
    main()
except (Refusal, OSError) as err:
    print(f'fm-channel-intake: tickets: {err}; snapshot left unchanged', file=sys.stderr)
    sys.exit(2)
