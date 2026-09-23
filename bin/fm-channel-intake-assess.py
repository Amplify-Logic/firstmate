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
# carrying one of these is an open commitment until a later reply follows.
PROMISE = re.compile(
    r"looking into|look into|check(?:ing)?\b.{0,40}\bwith\b|escalat|get back to you|come back to you"
    r"|let you know|keep you (?:updated|posted|informed)|update you|once (?:i|we) hear"
    r"|(?:will|i'll|we'll)\s+(?:confirm|update|follow up|revert|share|send)|follow(?:ing)? up"
    r"|induiken|achteraan|\bkom\b.{0,60}\bterug\b|\blaat\b.{0,60}\bweten\b|stuur je een update"
    r"|uitzoeken|nakijken|navragen|terugkoppel|op de hoogte",
    re.I | re.S)
TECH = re.compile(r"\btech\b|\btechteam\b|\btechnical (?:team|support|department)\b", re.I)
QUOTE_START = re.compile(
    r"^\s*(?:>|on .{0,120}wrote:|op .{0,120}schreef|-{2,}\s*original message|from:\s|van:\s|sent from my)",
    re.I)
ADDRESS = re.compile(r'^[^\s<>,@]+@[^\s<>,@]+\.[^\s<>,@]+$')
MAIL_DOMAIN = re.compile(r'^[^\s<>,@]+\.[^\s<>,@]+$')


class Refusal(Exception):
    pass


def words(value):
    return [w for w in re.split(r'[\s,]+', value or '') if w]


def fresh_text(body):
    """The message's own words: quoted history below a reply marker is dropped."""
    kept = []
    for line in body.splitlines():
        if QUOTE_START.match(line):
            break
        kept.append(line)
    return '\n'.join(kept)


def domain(address):
    address = address.strip().lower()
    return address.rsplit('@', 1)[1] if '@' in address else ''


def text_field(value, what):
    """A timeline string, absent reading as empty; any other shape is refused."""
    if value is None:
        return ''
    if not isinstance(value, str):
        raise Refusal(f'{what} must be a string')
    return value


def address_field(value, what):
    """A bare local@domain: a display-name spelling hides the address it wraps."""
    value = text_field(value, what)
    if value and not ADDRESS.match(value):
        raise Refusal(f'{what} must be a bare local@domain address: {value}')
    return value


def identity_field(value, what):
    value = text_field(value, what)
    if value.strip().lower() == 'captain':
        return value
    if value and not ADDRESS.match(value):
        raise Refusal(f'{what} must be `captain` or a bare local@domain address: {value}')
    return value


def address_list(value, what):
    if value is None:
        return []
    if not isinstance(value, list):
        raise Refusal(f'{what} must be a list of addresses')
    return [address_field(a, f'{what} entry') for a in value]


def epoch_second(value):
    """A positive epoch second; a millisecond epoch is refused, not read as far future."""
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value < 10 ** 11


def when(epoch):
    return time.strftime('%a %-d %b %H:%M', time.localtime(int(epoch)))


def load(path):
    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise Refusal(f'timeline is not readable JSON: {exc}')
    if not isinstance(doc, dict) or doc.get('kind') != 'hubspot-ticket':
        raise Refusal('timeline kind must be hubspot-ticket')
    doc['owner'] = identity_field(doc.get('owner'), 'timeline owner')
    sent = doc.get('last_message_sent_at')
    if sent is not None and not epoch_second(sent):
        raise Refusal('timeline last_message_sent_at must be an epoch second')
    doc['contacts'] = address_list(doc.get('contacts'), 'timeline contacts')
    companies = doc.get('companies')
    if companies is not None and not isinstance(companies, list):
        raise Refusal('timeline companies must be a list')
    for n, company in enumerate(companies or []):
        if not isinstance(company, dict):
            raise Refusal(f'timeline company {n} must be an object')
        company['domain'] = text_field(company.get('domain'), f'timeline company {n} domain')
        if company['domain'] and not MAIL_DOMAIN.match(company['domain']):
            raise Refusal(f'timeline company {n} domain must be a bare mail domain: ' + company['domain'])
    doc['companies'] = companies or []
    events = doc.get('events')
    if not isinstance(events, list):
        raise Refusal('timeline events must be a list')
    clean = []
    for n, e in enumerate(events):
        if not isinstance(e, dict) or e.get('type') not in ('email', 'note'):
            raise Refusal(f'timeline event {n} must be an email or a note')
        at = e.get('at')
        if not epoch_second(at):
            raise Refusal(f'timeline event {n} needs an epoch-second at')
        if e['type'] == 'email' and e.get('direction') not in ('inbound', 'outbound'):
            raise Refusal(f'timeline email {n} needs direction inbound or outbound')
        e['author'] = identity_field(e.get('author'), f'timeline event {n} author')
        e['body'] = text_field(e.get('body'), f'timeline event {n} body')
        e['from'] = address_field(e.get('from'), f'timeline event {n} from')
        e['to'] = address_list(e.get('to'), f'timeline event {n} to')
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

    def is_captain(who):
        """One spelling of the captain everywhere: the sentinel or his address."""
        who = who.strip().lower()
        return who == 'captain' or who in captain_addresses

    def by_captain(e):
        return is_captain(e['author']) or is_captain(e['from'])

    def is_answer(e):
        """A real reply: an EMAIL engagement sent from the team mailbox or by the captain."""
        return (e['type'] == 'email' and e['direction'] == 'outbound'
                and (e['from'].lower() in answer_addresses or by_captain(e)))

    events = doc['events']
    external = set()
    # Only a mail domain places someone outside the team, and it counts wherever
    # the ticket carries it: a company record with no domain says nothing.
    participants = [a for e in events for a in [e['from']] + e['to']]
    for address in (doc['contacts'] + participants
                    + ['x@' + c['domain'] for c in doc['companies'] if c['domain']]):
        if domain(address) and domain(address) not in internal:
            external.add(domain(address))
    partner = bool(external)

    captain_owned = is_captain(doc['owner'])
    named = any(names_captain(fresh_text(e['body'])) for e in events)
    pending = []

    def answered_after(at, note_answers=False):
        return any(e['at'] > at and (is_answer(e) or (note_answers and e['type'] == 'note' and by_captain(e)))
                   for e in events)

    # (b) A promise naming the captain or the tech team, or the captain's own
    # promise, with no later reply after it.
    tech_promise = False
    for e in events:
        if e['type'] != 'email' or e['direction'] != 'outbound':
            continue
        text = fresh_text(e['body'])
        if not PROMISE.search(text):
            continue
        who = 'you' if names_captain(text) or by_captain(e) else ('tech' if TECH.search(text) else '')
        if not who:
            continue
        tech_promise = tech_promise or who == 'tech'
        if not answered_after(e['at']):
            pending.append((e['at'], f'the {when(e["at"])} promise that {"you are" if who == "you" else "tech is"} on it has had no message since'))

    # (c) A colleague's note naming the captain, unanswered by his note or a reply.
    for e in events:
        if e['type'] != 'note' or by_captain(e):
            continue
        if not names_captain(fresh_text(e['body'])):
            continue
        if not answered_after(e['at'], note_answers=True):
            pending.append((e['at'], f'the {when(e["at"])} colleague note asking you is unanswered'))

    # (a) The partner's last message unanswered. Only a later reply discharges
    # it; a HubSpot send with no EMAIL engagement is an auto-acknowledgement.
    involved = captain_owned or named or tech_promise
    inbound = [e for e in events if e['type'] == 'email' and e['direction'] == 'inbound']
    if involved and inbound:
        last = inbound[-1]
        if not answered_after(last['at']):
            why = f'the partner\'s {when(last["at"])} message has no reply'
            sent = doc.get('last_message_sent_at')
            no_email_since = not any(e['type'] == 'email' and e['direction'] == 'outbound'
                                     and e['at'] > last['at'] for e in events)
            if sent and sent > last['at'] and no_email_since:
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
