#!/usr/bin/env python3
"""Private partner-facing and awaiting-the-captain assessor for fm-channel-intake.sh.

`observe --timeline-file` owns the contract; this reads one timeline the
orchestrator wrote, prints key=value facts, and never stores a message body.
"""
import argparse
import json
import re
import sys
import time

# A promise to act, in the languages the support timelines use. An outbound
# carrying one of these is an open commitment until a later outbound follows.
PROMISE = re.compile(
    r"looking into|look into|check(?:ing)?\b.{0,40}\bwith\b|escalat|get back to you|come back to you"
    r"|let you know|keep you (?:updated|posted|informed)|update you|once (?:i|we) hear"
    r"|(?:will|i'll|we'll)\s+(?:confirm|update|follow up|revert|share|send)|follow(?:ing)? up"
    r"|induiken|achteraan|\bkom\b.{0,60}\bterug\b|\blaat\b.{0,60}\bweten\b|stuur je een update"
    r"|uitzoeken|nakijken|navragen|terugkoppel|op de hoogte",
    re.I | re.S)
TECH = re.compile(r"\btech\b|\btechteam\b|\btechnical (?:team|support|department)\b", re.I)
THANKS = re.compile(r"\b(?:thanks|thank you|thx|bedankt|dank je|dankjewel|dank u|takk|merci|danke)\b", re.I)
QUOTE_START = re.compile(
    r"^\s*(?:>|on .{0,120}wrote:|op .{0,120}schreef|-{2,}\s*original message|from:\s|van:\s|sent from my)",
    re.I)
WAITING_ON_CONTACT = 'waiting on contact'


class Refusal(Exception):
    pass


def words(value):
    return [w for w in re.split(r'[\s,]+', value or '') if w]


def fresh_text(body):
    """The message's own words: quoted history below a reply marker is dropped."""
    kept = []
    for line in str(body or '').splitlines():
        if QUOTE_START.match(line):
            break
        kept.append(line)
    return '\n'.join(kept)


def domain(address):
    address = str(address or '').strip().lower()
    return address.rsplit('@', 1)[1] if '@' in address else ''


def when(epoch):
    return time.strftime('%a %-d %b %H:%M', time.localtime(int(epoch)))


def load(path):
    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise Refusal(f'timeline is not readable JSON: {exc}')
    if not isinstance(doc, dict) or doc.get('kind') not in ('hubspot-ticket', 'email-thread'):
        raise Refusal('timeline kind must be hubspot-ticket or email-thread')
    events = doc.get('events')
    if not isinstance(events, list):
        raise Refusal('timeline events must be a list')
    clean = []
    for n, e in enumerate(events):
        if not isinstance(e, dict) or e.get('type') not in ('email', 'note'):
            raise Refusal(f'timeline event {n} must be an email or a note')
        at = e.get('at')
        if not isinstance(at, int) or isinstance(at, bool) or at <= 0:
            raise Refusal(f'timeline event {n} needs an epoch-second at')
        if e['type'] == 'email' and e.get('direction') not in ('inbound', 'outbound'):
            raise Refusal(f'timeline email {n} needs direction inbound or outbound')
        clean.append(e)
    # Stable order: equal times keep the order the orchestrator listed them in.
    doc['events'] = sorted(clean, key=lambda e: e['at'])
    return doc


def assess(doc, names, captain_addresses, team_addresses):
    captain_addresses = {a.lower() for a in captain_addresses}
    answer_addresses = captain_addresses | {a.lower() for a in team_addresses}
    internal = {domain(a) for a in answer_addresses if domain(a)}
    name_re = re.compile(r'(?<![\w.@-])@?(?:' + '|'.join(re.escape(n) for n in names) + r')\b', re.I) if names else None

    def names_captain(text):
        return bool(name_re and name_re.search(text))

    def by_captain(e):
        return e.get('author') == 'captain' or str(e.get('from', '')).lower() in captain_addresses

    def is_answer(e):
        """A real reply: an EMAIL engagement sent from the team mailbox or by the captain."""
        return (e['type'] == 'email' and e['direction'] == 'outbound'
                and (str(e.get('from', '')).lower() in answer_addresses or by_captain(e)))

    events = doc['events']
    external = set()
    for address in doc.get('contacts') or []:
        if domain(address) and domain(address) not in internal:
            external.add(domain(address))
    for company in doc.get('companies') or []:
        company = company if isinstance(company, dict) else {'name': company}
        if company.get('name') and domain('x@' + str(company.get('domain') or '')) not in internal:
            external.add(str(company.get('domain') or company['name']).lower())
    if doc['kind'] == 'email-thread':
        for e in events:
            for address in [e.get('from')] + list(e.get('to') or []):
                if domain(address) and domain(address) not in internal:
                    external.add(domain(address))
    partner = bool(external)

    captain_owned = doc.get('owner') == 'captain'
    named = any(names_captain(fresh_text(e.get('body'))) for e in events)
    pending = []

    def answered_after(at, note_answers=False):
        return any(e['at'] > at and (is_answer(e) or (note_answers and e['type'] == 'note' and by_captain(e)))
                   for e in events)

    # (b) A promise naming the captain or the tech team, or the captain's own
    # promise, with no outbound after it.
    tech_promise = False
    for e in events:
        if e['type'] != 'email' or e['direction'] != 'outbound':
            continue
        text = fresh_text(e.get('body'))
        if not PROMISE.search(text):
            continue
        who = 'you' if names_captain(text) or by_captain(e) else ('tech' if TECH.search(text) else '')
        if not who:
            continue
        tech_promise = tech_promise or who == 'tech'
        if not answered_after(e['at']):
            pending.append((e['at'], f'the {when(e["at"])} promise that {"you are" if who == "you" else "tech is"} on it has had no message since'))

    # (c) A colleague's note asking the captain, unanswered by his note or a reply.
    for e in events:
        if e['type'] != 'note' or by_captain(e):
            continue
        text = fresh_text(e.get('body'))
        if not (names_captain(text) or (captain_owned and '?' in text)):
            continue
        if not answered_after(e['at'], note_answers=True):
            pending.append((e['at'], f'the {when(e["at"])} colleague note asking you is unanswered'))

    # (a) The partner's last message unanswered. A HubSpot send with no EMAIL
    # engagement is an auto-acknowledgement, and "Waiting on contact" is the
    # stage where the customer owes the next step, so neither counts here.
    involved = captain_owned or named or tech_promise
    stage = str(doc.get('stage') or '').strip().lower()
    inbound = [e for e in events if e['type'] == 'email' and e['direction'] == 'inbound']
    if involved and inbound and stage != WAITING_ON_CONTACT:
        last = inbound[-1]
        text = fresh_text(last.get('body'))
        courtesy = THANKS.search(text) and len(text.split()) <= 25 and '?' not in text
        if not courtesy and not answered_after(last['at']):
            why = f'the partner\'s {when(last["at"])} message has no reply'
            sent = doc.get('last_message_sent_at')
            if isinstance(sent, int) and sent > last['at']:
                why += f' (the {when(sent)} send has no email: an auto-acknowledgement)'
            pending.append((last['at'], why))

    pending.sort()
    awaiting = partner and bool(pending)
    return {
        'partner': '1' if partner else '0',
        'awaiting': '1' if awaiting else '0',
        'awaiting_since': str(pending[0][0]) if awaiting else '',
        'awaiting_why': '; '.join(w for _, w in pending) if awaiting else '',
    }


def main():
    parser = argparse.ArgumentParser(prog='fm-channel-intake-assess.py')
    parser.add_argument('--timeline', required=True)
    parser.add_argument('--names', default='')
    parser.add_argument('--captain-addresses', default='')
    parser.add_argument('--team-addresses', default='')
    args = parser.parse_args()
    try:
        facts = assess(load(args.timeline), words(args.names), words(args.captain_addresses),
                       words(args.team_addresses))
    except Refusal as exc:
        print(f'fm-channel-intake: {exc}', file=sys.stderr)
        return 2
    for key in ('partner', 'awaiting', 'awaiting_since', 'awaiting_why'):
        print(f'{key}=' + ' '.join(facts[key].split()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
