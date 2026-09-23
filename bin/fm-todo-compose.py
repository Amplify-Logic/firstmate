#!/usr/bin/env python3
"""Private composition helper for fm-todo-render.sh; its header owns the contract."""
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sys
import time

STORE, MORNING, DAY, NOW, ZONE, HOME, MORNING_JSON, INTAKE, SOURCES = sys.argv[1:]
NOW = int(NOW)
if ZONE:
    os.environ['TZ'] = ZONE
    time.tzset()
RANK = {name: n for n, name in enumerate(('outage', 'urgent', 'deadline', 'obligation'))}
RETIRED = ('closed', 'dropped')


def esc(value):
    return html.escape(str(value), quote=True)


def number(value):
    try:
        return max(0, int(value))
    except (ValueError, TypeError):
        return 0


def stamp(epoch, fmt='%H:%M %Z'):
    return time.strftime(fmt, time.localtime(int(epoch)))


def when(epoch):
    """A read time, with the day added whenever it is not the page's day."""
    epoch = number(epoch)
    if not epoch:
        return 'an unrecorded time'
    if stamp(epoch, '%Y-%m-%d') == DAY:
        return stamp(epoch)
    return stamp(epoch, '%a %-d %b %H:%M %Z')


def day_start(epoch):
    t = time.localtime(int(epoch))
    return int(time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1)))


class Fragment(HTMLParser):
    """Normalize old document wrappers without guessing actionable content."""
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

    def __init__(self, text):
        super().__init__(convert_charrefs=False)
        self.root = ['', {}, []]
        self.stack = [self.root]
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        node = [tag, dict(attrs), []]
        self.stack[-1][2].append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def handle_data(self, value):
        self.stack[-1][2].append(value)

    def handle_entityref(self, name):
        self.handle_data('&' + name + ';')

    def handle_charref(self, name):
        self.handle_data('&#' + name + ';')

    def blocks(self, nodes=None):
        for node in self.root[2] if nodes is None else nodes:
            if isinstance(node, str):
                yield node
                continue
            tag, attrs, children = node
            classes = (attrs.get('class') or '').split()
            if tag in {'head', 'header', 'h1', 'script', 'style'} or 'legend' in classes:
                continue
            if tag in {'html', 'body'} or 'wrap' in classes:
                yield from self.blocks(children)
            else:
                yield node

    def render(self, node):
        if isinstance(node, str):
            return node
        tag, attrs, children = node
        attributes = ''.join(' ' + k + (f'="{esc(v)}"' if v is not None else '') for k, v in attrs.items())
        content = ''.join(self.render(n) for n in children)
        return f'<{tag}{attributes}>' + content + ('' if tag in self.VOID else f'</{tag}>')

    def text(self, node):
        return node if isinstance(node, str) else ''.join(self.text(n) for n in node[2])

    def drop(self, heading, nodes=None):
        """Remove every h2 whose text matches `heading`, with what follows it up to the next h2, at any depth."""
        nodes = self.root[2] if nodes is None else nodes
        kept, dropping, found = [], False, False
        for node in nodes:
            if not isinstance(node, str) and node[0] == 'h2':
                dropping = bool(re.match(heading, self.text(node).strip(), re.I))
                found = found or dropping
            if not dropping:
                if not isinstance(node, str):
                    found = self.drop(heading, node[2]) or found
                kept.append(node)
        nodes[:] = kept
        return found

    def html(self):
        return ''.join(self.render(n) for n in self.root[2])

    def sections(self):
        groups = []
        for node in self.blocks():
            if not isinstance(node, str) and node[0] == 'h2':
                groups.append([])
            if not groups:
                groups.append([])
            groups[-1].append(node)
        return [''.join(self.render(n) for n in group) for group in groups]


# --- inputs -----------------------------------------------------------------

items = []
items_dir = Path(STORE) / 'items'
if items_dir.is_dir():
    for path in sorted(items_dir.glob('*.json')):
        if path.is_file() and not path.is_symlink():
            items.append(json.loads(path.read_text()))
sweeps = []
if (Path(STORE) / 'sweeps').is_file():
    sweeps = sorted(number(x) for x in (Path(STORE) / 'sweeps').read_text().split() if 0 < number(x) <= NOW)
# The freshness floor is this build's verification sweep, never earlier than
# the page's own day. A line whose recorded check predates it, or checked a
# different revision than the one shown, is labelled not re-checked.
FLOOR = max([day_start(NOW)] + [s for s in sweeps if stamp(s, '%Y-%m-%d') == DAY])
# Closed since: the sweep before this one, else the start of the day. Stable
# through the day, so background rebuilds never shrink it.
earlier = [s for s in sweeps if s < FLOOR]
SINCE = earlier[-1] if earlier else day_start(NOW)
sidecar = json.loads(Path(MORNING_JSON).read_text()) if MORNING_JSON else {}


def current(rec):
    v = rec.get('verification') or {}
    return number(v.get('at')) >= FLOOR and v.get('rev') == rec.get('rev')


def sortkey(rec):
    return RANK.get(rec.get('class'), 99), -number((rec.get('verification') or {}).get('at')), rec.get('id', '')


def queued(rec):
    """Oldest first by the date the source says it has been waiting; undated last."""
    return rec.get('since') or '9999-12-31', sortkey(rec)


# --- rows -------------------------------------------------------------------

def brief(text, limit=240):
    """One readable line; the full text stays in the hover title."""
    text = ' '.join(str(text).split())
    if len(text) <= limit:
        return esc(text)
    return f'<span title="{esc(text)}">{esc(text[:limit].rsplit(" ", 1)[0])}…</span>'


def link(url):
    if re.match(r'^https?://', url or '', re.I):
        return f'<a href="{esc(url)}" target="_blank" rel="noreferrer">Open</a>'
    return '<span class="nolink">no link recorded</span>'


def freshness(rec):
    v = rec.get('verification') or {}
    if current(rec):
        return f'<span class="prov obs">read {esc(when(v.get("at")))}</span>'
    if number(v.get('at')):
        return f'<span class="prov unv">not re-checked since {esc(when(v.get("at")))}</span>'
    return '<span class="prov unv">cannot verify - no source read recorded</span>'


def reply_form(rec):
    """Hidden full-width note row; the queued text names the id and the revision shown."""
    iid = rec.get('id') or ''
    rev = rec.get('rev') or ''
    title_raw = rec.get('title') or 'untitled item'
    js = (
        "event.preventDefault();"
        "var f=event.currentTarget,v=f.note.value.trim();if(!v)return;"
        "if(!window.lavish||!window.lavish.queuePrompt){f.querySelector('.ack').textContent="
        "'review session not connected';return;}"
        "window.lavish.queuePrompt("
        f"'Update on to-do item '+{json.dumps(iid)}+' rev '+{json.dumps(rev)}+' ('+{json.dumps(title_raw)}+'): '+v,"
        "{tag:'item-update',"
        f"text:{json.dumps(title_raw[:70])}+': '+v,"
        "element:f,"
        f"queueKey:{json.dumps('todo-item-' + iid)},"
        f"data:{{item_id:{json.dumps(iid)},rev:{json.dumps(rev)},title:{json.dumps(title_raw)},note:v}}}});"
        "f.note.value='';f.querySelector('.ack').textContent='queued';"
    )
    return (f'<tr class="replyrow" id="note-{esc(iid)}"><td colspan="3">'
            f'<form class="reply" data-lavish-question="todo-item-{esc(iid)}" onsubmit="{esc(js)}">'
            f'<input type="text" name="note" autocomplete="off" '
            f'placeholder="drop, done, park til Friday, mine, you: what to do, dig, or anything else">'
            f'<button type="submit">Queue</button><span class="ack"></span>'
            f'</form></td></tr>')


def note_toggle(rec):
    iid = esc(rec.get('id') or '')
    js = ("var r=document.getElementById('note-" + iid + "');"
          "var o=r.classList.toggle('open');"
          "this.setAttribute('aria-expanded',o);"
          "if(o){r.querySelector('input').focus();}")
    return f'<button type="button" class="notetoggle" aria-expanded="false" onclick="{esc(js)}">note</button>'


def row(rec, reply=True):
    title = esc(rec.get('title') or 'untitled item')
    severity = rec.get('class', 'obligation')
    pill = {'outage': 'bad', 'urgent': 'warn', 'deadline': 'warn'}.get(severity, 'info')
    ctx = ''
    if rec.get('ask') and rec.get('ask') != rec.get('title'):
        ctx += f'<span class="ctx">{brief(rec["ask"])}</span>'
    if rec.get('note'):
        ctx += f'<span class="next"><b>{esc(rec["note"])}</b></span>'
    how = (rec.get('verification') or {}).get('how') or 'no verification recorded'
    ctx += f'<span class="ctx how">{esc(how)}</span>'
    toggle = note_toggle(rec) if reply else ''
    main = (f'<tr class="item" id="item-{esc(rec.get("id", ""))}"><td class="who"><span class="pill {pill}">{esc(severity)}</span><span class="org">{esc(rec.get("label", ""))}</span></td>\n'
            f'<td class="what">{title}{freshness(rec)}{ctx}</td>\n'
            f'<td class="links">{link(rec.get("link"))}{toggle}</td></tr>')
    return main + '\n' + reply_form(rec) if reply else main


def table(rows):
    return '<div class="tablewrap"><table><tbody>\n' + '\n'.join(rows) + '\n</tbody></table></div>'


def disclosure(title, content):
    return f'<details><summary>{esc(title)}</summary>\n{content}\n</details>'


def listing(recs, note):
    return '<ul class="done">' + ''.join(
        f'<li id="item-{esc(r["id"])}"><b>{esc(r.get("title"))}</b> - {brief(note(r))}<span class="why">{esc(r.get("label", ""))} · {freshness(r)}</span></li>'
        for r in recs) + '</ul>'


def capped(recs, more, reply=True, limit=0):
    """At most `limit` rows and a count of the rest; limit 0 shows every row."""
    shown = recs[:limit] if limit else recs
    body = table([row(r, reply=reply) for r in shown])
    if len(recs) > len(shown):
        body += f'\n<p class="sub">{len(recs) - len(shown)} {esc(more)}</p>'
    return body


def stale_fold(recs, reply=True, limit=0):
    """The one labelled fold every section uses for lines this build did not re-check."""
    if limit and len(recs) > limit:
        recs = sorted(recs, key=lambda r: (number((r.get('verification') or {}).get('at')), r.get('id', '')))
        summary = f'{len(recs)} not re-checked in this build, oldest {limit} shown'
    else:
        summary, limit = f'{len(recs)} not re-checked in this build - each shows its last check', 0
    return disclosure(summary, capped(recs, 'more not re-checked, not shown here.', reply, limit))


def split(recs):
    return sorted((r for r in recs if current(r)), key=sortkey), sorted((r for r in recs if not current(r)), key=sortkey)


def section(heading, small, recs):
    """Current lines in the table, older ones in one labelled fold; empty sections are omitted."""
    if not recs:
        return
    print(f'<h2>{esc(heading)}<small>{esc(small)}</small></h2>')
    live, stale = split(recs)
    if live:
        print(table([row(r) for r in live]))
    else:
        print('<p class="sub">None re-checked in this build.</p>')
    if stale:
        print(stale_fold(stale))


# --- morning detail fragment ------------------------------------------------

# The open-tickets section is rendered live from the intake's snapshot, so a
# morning copy of it is always older and never shown.
TICKETS_HEADING = r'Your open tickets\b'

reference = ''
details = ''
if MORNING:
    path = Path(MORNING)
    if MORNING_JSON:
        # A structured fragment contains detail only, never another document shell.
        details = path.read_text()
        if re.search(r'<(?:html|head|body|header|h1)\b', details, re.I):
            raise ValueError('structured morning HTML must be a details-only fragment')
        parsed = Fragment(details)
        if parsed.drop(TICKETS_HEADING):
            details = parsed.html()
    else:
        # Old arbitrary prose has no reliable action identity or per-item read
        # time. Never promote it to an open action or pretend a rebuild verified it.
        legacy = Fragment(path.read_text())
        legacy.drop(TICKETS_HEADING)
        for part in legacy.sections():
            if re.match(r'<h2\b[^>]*>Pilot-partner connectivity\b', part, re.I):
                continue
            if re.match(r'<h2\b[^>]*>(?:Calendar|Support pipeline)\b', part, re.I):
                details += '<section class="morning-context"><p class="sub">Morning snapshot - original read times retained</p>' + part + '</section>'
            else:
                reference += part
        reference = disclosure('Earlier morning reference - not re-verified by this update',
                               '<p class="sub">Historical snapshot. Re-check sources before treating these lines as open.</p>' + reference)

# --- partition ----------------------------------------------------------------

today = DAY
snoozed, mine, handoffs, live = [], [], [], []
for rec in items:
    if rec.get('state') != 'open':
        continue
    until = max(rec.get('snoozed_until') or '', rec.get('source_snooze') or '')
    if until > today:
        snoozed.append(rec)
    elif rec.get('pending'):
        handoffs.append(rec)
    elif rec.get('owner') == 'captain':
        mine.append(rec)
    else:
        live.append(rec)



def held(rec):
    """A captain-held backlog task: a hold time is never a source read, so it is never current."""
    return any(slot.startswith('backlog:') for slot in (rec.get('slots') or {}))


asks = [r for r in live if r.get('kind') in ('decision', 'approval')]
# Holds nobody re-checked this build get their own capped fold, so ~95 of them
# cannot bury the decisions that were actually read today.
decisions = [r for r in asks if not (held(r) and not current(r))]
holds = [r for r in asks if held(r) and not current(r)]
replies = [r for r in live if r.get('kind') == 'reply']
conditions = [r for r in live if r.get('kind') == 'condition']
activity = [r for r in live if r.get('kind') == 'info']
waiting = sorted([r for r in items if r.get('state') == 'waiting'] + handoffs, key=sortkey)


def intake_retired(rec):
    """Routine chatter the intake dropped from its ledger; it was never an ask to close."""
    c = rec.get('closure') or {}
    return rec.get('kind') == 'info' and c.get('reason') == 'superseded' and c.get('actor') == 'source'


closed = [r for r in items if r.get('state') == 'closed' and not intake_retired(r)
          and number((r.get('closure') or {}).get('at')) >= SINCE]
closed.sort(key=lambda r: (-number(r['closure'].get('at')), r['id']))
# Counted as handled without you only with a named actor other than the
# captain and a fulfilled close; unknown actors, dismissals and releases never count.
handled = [r for r in closed if r['closure'].get('reason') == 'fulfilled'
           and r['closure'].get('actor') not in ('captain', 'source', 'unknown', '')]
now_strip = sorted((r for r in decisions + replies if current(r)), key=sortkey)[:3]

# --- page -------------------------------------------------------------------

sweep_line = (f'Verification sweep began <span class="mono">{esc(when(FLOOR))}</span>.' if FLOOR != day_start(NOW)
              else 'No verification sweep recorded today; only reads recorded today count as current.')
print(f'<p class="sub">{sweep_line} A line not re-read since then says so on the line.</p>')
print('<div class="tiles">')
decisions_sub = f'{len(decisions)} open in all' + (f' · {len(holds)} held, not re-checked' if holds else '')
tiles = [(len([r for r in decisions if current(r)]), 'Decisions awaiting you', decisions_sub),
         (len([r for r in replies if current(r)]), 'Replies you owe', f'{len(replies)} open in all'),
         (len(waiting), 'Waiting on others', 'nothing needed from you'),
         (len(closed), f'Closed since {when(SINCE)}', 'each with its evidence below')]
if handled:
    tiles.append((len(handled), 'Handled without you', 'closed by a named colleague or firstmate'))
for n, label, sub in tiles:
    print(f'<div class="tile"><div class="n">{n}</div><div class="l">{esc(label)}</div><div class="s">{esc(sub)}</div></div>')
print('</div>')

print('<div class="strip now"><h3>Now</h3><p class="sub">at most three, re-checked in this build</p>')
if now_strip:
    print('<ol>')
    for r in now_strip:
        why = r.get('why') or r.get('ask') or f'{r.get("class")} {"reply owed" if r.get("kind") == "reply" else "decision"}, read {when(r["verification"].get("at"))}'
        print(f'<li><a class="jump" href="#item-{esc(r["id"])}">{esc(r.get("title"))}</a><span class="why">{brief(why, 160)}</span></li>')
    print('</ol>')
else:
    print('<p class="sub"><b>Nothing open.</b> No action re-checked in this build is waiting on you.</p>')
print('</div>')

section('Decisions awaiting you', 'urgent first, newest within each priority', decisions)
if holds:
    # Oldest hold first: nothing re-reads a hold, so without its queued date the
    # cut would be hash order and the same ten would surface every day.
    print(disclosure(f'Held decisions not re-checked ({len(holds)})',
                     capped(sorted(holds, key=queued), 'more held for you, not shown here.', limit=10)))
section('Replies you owe', 'read by the intake or the morning sweep', replies)

# The email agent block is DATED REFERENCE from the file the morning sidecar
# names, never a fresh obligation and never selected by guessing the newest.
email = sidecar.get('email_agent_source') or ''
email_path = Path(email if email.startswith('/') else Path(HOME) / email) if email else None
if email_path and email_path.is_file() and not email_path.is_symlink():
    blocks, heading = {}, ''
    for line in email_path.read_text().splitlines():
        if line.startswith('## '):
            heading = line[3:].strip().lower()
            continue
        entry = re.match(r'^\s*(?:[-*]|\d+\.)\s+(.*)$', line)
        if heading and entry:
            blocks.setdefault(heading, []).append(re.sub(r'[*`]', '', entry.group(1)).strip())

    def pick(prefix, limit):
        return next((v[:limit] for k, v in blocks.items() if k.startswith(prefix)), [])

    print('<h2>Email agent replies<small>dated reference, not fresh obligations</small></h2>')
    print(f'<p class="sub"><span class="prov inf">from {esc(email_path.name)}, written {esc(when(int(email_path.stat().st_mtime)))}</span></p>')
    print('<div class="grid2">')
    for title, lines in (('Next actions', pick('next actions', 3)), ('In flight', pick('in flight', 4)),
                         ('Landed', pick('landed', 4))):
        if lines:
            print(f'<div class="card"><h3>{esc(title)}</h3><ol>' + ''.join(f'<li>{brief(l)}</li>' for l in lines) + '</ol></div>')
    print('</div>')

if waiting:
    print('<h2>Waiting on others<small>nothing needed from you unless it comes back</small></h2>')

    def waiting_note(r):
        if r.get('pending'):
            return f'handoff requested, not yet accepted: {r["pending"].get("what")}'
        return (f'{r.get("owner")} has it: ' if r.get('owner') else 'handed over: ') + (r.get('handover') or 'no hand-over note recorded')
    print(listing(waiting, waiting_note))

watch = {}
for rec in conditions:
    title = rec.get('title', '')
    # Only the two enrolled fault conditions. No silence/offline classifier.
    for condition, pattern in [('B.14', r'B\.14'), ('Freezing coolers', r'coolers? under 1\s*°?\s*C|freezing')]:
        if re.search(pattern, title, re.I):
            watch.setdefault(condition, []).append(rec)
if watch:
    print('<h2>Watching<small>conditions, not additional tasks</small></h2>')
for condition, readings in sorted(watch.items()):
    readings.sort(key=lambda r: (-number((r.get('verification') or {}).get('at')), r['id']))
    # A full count and a later delta are different evidence. Never add reads
    # together or silently treat a delta as the current whole-fleet count.
    count_pattern = r'(\d+) active B\.14 units' if condition == 'B.14' else r'(\d+) coolers under 1\s*°?\s*C'
    count = next(((r, re.search(count_pattern, r.get('title', ''), re.I)) for r in readings
                  if re.search(count_pattern, r.get('title', ''), re.I)), None)
    summary = 'count not recorded'
    if count:
        rec, match = count
        summary = f'{match.group(1)} units at {when(rec["verification"].get("at"))}'
    newest = readings[0]
    title = newest.get('title', '')
    units = title.split('; newest:', 1)[1].strip() if '; newest:' in title else (title if re.search(r'\b\d{15}\b', title) else 'no unit detail in latest observation')
    print(f'<div class="watch-line"><b>{esc(condition)}</b> - {esc(summary)}'
          f'<span class="why">Latest: {esc(units)} · {esc(newest.get("label", ""))} · {freshness(newest)} · {link(newest.get("link"))}</span></div>')

# --- open tickets -------------------------------------------------------------

TICKETS_FRESH = 3600  # the HubSpot pass runs every 30 minutes; an hour means it missed


def tickets_snapshot():
    """The intake's snapshot, or the plain reason it cannot be shown."""
    path = Path(INTAKE) / 'tickets.json' if INTAKE else None
    if not path or not path.is_file() or path.is_symlink():
        return None, 'no HubSpot read has been recorded'
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return None, 'the snapshot file is not valid JSON'
    if not isinstance(doc, dict) or doc.get('version') != 1 or not number(doc.get('read_at')) \
            or not isinstance(doc.get('tickets'), list) \
            or not all(isinstance(t, dict) and isinstance(t.get('id'), str) for t in doc['tickets']):
        return None, 'the snapshot file is not in the expected format'
    return doc, ''


def tickets_section():
    doc, why = tickets_snapshot()
    if doc is None:
        print('<h2>Your open tickets<small>not available</small></h2>')
        print(f'<p class="sub"><span class="prov unv">Could not read your open tickets: {esc(why)}.</span></p>')
        return
    read_at, tickets = number(doc['read_at']), doc['tickets']
    age = NOW - read_at
    counts = {}
    for t in tickets:
        counts[t.get('stage', '')] = counts.get(t.get('stage', ''), 0) + 1
    breakdown = ', '.join(f'{n} {esc(stage)}' for stage, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    noun = 'ticket carries' if len(tickets) == 1 else 'tickets carry'
    summary = f'{len(tickets)} {noun} you as owner and {"is" if len(tickets) == 1 else "are"} not closed' + (f': {breakdown}' if breakdown else '') + '.'
    if age > TICKETS_FRESH:
        print(f'<h2>Your open tickets<small>out of date - last read {esc(when(read_at))}</small></h2>')
        print(f'<p class="sub"><span class="prov unv">Not refreshed since {esc(when(read_at))}, {age // 60} minutes ago; '
              f'stages may have changed since.</span> At that read: {summary}</p>')
    else:
        print('<h2>Your open tickets<small>read live from HubSpot</small></h2>')
        print(f'<p class="sub">{summary} <span class="prov obs">Read live from HubSpot at {esc(when(read_at))}.</span></p>')
    if not tickets:
        return
    rows = ''.join(
        f'<tr><td>{link_to(t.get("link"), t.get("subject") or "untitled ticket")}</td><td>{esc(t.get("stage", ""))}</td>'
        f'<td>{esc(t.get("last_in") or "-")}</td><td>{esc(t.get("last_out") or "-")}</td></tr>'
        for t in tickets)
    print('<div class="tablewrap"><table><thead><tr><th>Ticket</th><th>Stage</th><th>Last inbound</th><th>Last outbound</th></tr></thead>'
          f'<tbody>{rows}</tbody></table></div>')


def link_to(url, label):
    if re.match(r'^https?://', url or '', re.I):
        return f'<a href="{esc(url)}" target="_blank" rel="noreferrer">{esc(label)}</a>'
    return esc(label)


tickets_section()
if details:
    print('<section aria-label="Tickets and calendar">' + details + '</section>')

if closed:
    print(f'<h2>Closed since {esc(when(SINCE))}<small>each with its closing evidence</small></h2>')
    who = {'captain': 'by you', 'source': 'at the source', 'unknown': 'actor not recorded'}
    print(table([f'<tr class="closed"><td>{esc(r.get("title"))}</td><td>{brief(r["closure"].get("evidence") or "no closing evidence recorded")}</td>'
                 f'<td>{esc(r["closure"].get("reason", ""))} {esc(who.get(r["closure"].get("actor"), "by " + str(r["closure"].get("actor"))))} · {esc(r.get("label", ""))} · {esc(when(r["closure"].get("at")))}</td></tr>'
                 for r in closed]))

if snoozed:
    snoozed.sort(key=lambda r: (max(r.get('snoozed_until') or '', r.get('source_snooze') or ''), r['id']))
    print(disclosure(f'Parked ({len(snoozed)})', listing(snoozed, lambda r: f'back on {max(r.get("snoozed_until") or "", r.get("source_snooze") or "")}')))
if mine:
    print(disclosure(f'Yours, tracked but not surfaced ({len(mine)})', listing(sorted(mine, key=sortkey), lambda r: 'you said you are on it')))
if activity:
    fresh, older = split(activity)
    body = table([row(r, reply=False) for r in fresh]) if fresh else '<p class="sub">None re-checked in this build.</p>'
    if older:
        body += '\n' + stale_fold(older, reply=False, limit=10)
    print(disclosure('Other channel activity', body))

# Intake coverage is separate from item freshness: a store cannot fix a read that never ran.
enrolled = set()
if SOURCES and Path(SOURCES).is_file() and not Path(SOURCES).is_symlink():
    enrolled = {l.split('\t', 1)[0] for l in Path(SOURCES).read_text().splitlines() if l.strip()}
coverage = []
for state in sorted(Path(INTAKE).glob('sources/*/state')) if INTAKE else []:
    if state.is_symlink() or not state.is_file():
        continue
    rec = dict(l.split('=', 1) for l in state.read_text().splitlines() if '=' in l)
    if rec.get('id', state.parent.name) not in enrolled:
        continue
    ok = number(rec.get('last_ok'))
    line = f'<li><b>{esc(rec.get("id", state.parent.name))}</b> - last successful read {esc(when(ok) if ok else "never")}'
    if rec.get('error'):
        line += f'<span class="why">last attempt failed: {brief(rec["error"], 180)}</span>'
    coverage.append(line + '</li>')
if coverage:
    print(disclosure('Intake coverage', '<ul class="done">' + ''.join(coverage) + '</ul>'))
print(reference)
