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

DATA, MORNING, DAY, NOW, ZONE, SOURCES = sys.argv[1:]
if ZONE:
    os.environ['TZ'] = ZONE
    time.tzset()
RANK = {name: n for n, name in enumerate(('outage', 'urgent', 'deadline', 'obligation'))}

def esc(value):
    return html.escape(str(value), quote=True)

def stamp(epoch, fmt='%H:%M %Z'):
    return time.strftime(fmt, time.localtime(int(epoch)))

def number(value):
    try:
        return max(0, int(value))
    except (ValueError, TypeError):
        return 0

def records(folder):
    result = []
    for path in sorted((Path(DATA) / folder).glob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        rec = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
        rec['_id'] = rec.get('key', path.name)
        result.append(rec)
    return result

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

    def sections(self):
        groups = []
        for node in self.blocks():
            if not isinstance(node, str) and node[0] == 'h2':
                groups.append([])
            if not groups:
                groups.append([])
            groups[-1].append(node)
        return [''.join(self.render(n) for n in group) for group in groups]

labels = {}
if SOURCES and Path(SOURCES).is_file() and not Path(SOURCES).is_symlink():
    for line in Path(SOURCES).read_text().splitlines():
        fields = line.split('\t')
        if len(fields) >= 2:
            labels[fields[0]] = f'{fields[1]} ({fields[0]})'

def provenance(rec):
    source = rec.get('source', 'unattributed')
    return esc(labels.get(source, source))

def link(url):
    if re.match(r'^https?://', url or '', re.I):
        return f'<a href="{esc(url)}" target="_blank" rel="noreferrer">Open</a>'
    return '<span class="nolink">no link recorded</span>'

def reply_form(rec):
    """Hidden full-width note row, revealed by the toggle in the action column."""
    iid = rec.get('_id') or ''
    title_raw = rec.get('title') or 'untitled item'
    js = (
        "event.preventDefault();"
        "var f=event.currentTarget,v=f.note.value.trim();if(!v)return;"
        "if(!window.lavish||!window.lavish.queuePrompt){f.querySelector('.ack').textContent="
        "'review session not connected';return;}"
        "window.lavish.queuePrompt("
        f"'Update on to-do item '+{json.dumps(iid)}+' ('+{json.dumps(title_raw)}+'): '+v,"
        "{tag:'item-update',"
        f"text:{json.dumps(title_raw[:70])}+': '+v,"
        "element:f,"
        f"queueKey:{json.dumps('todo-item-' + iid)},"
        f"data:{{item_id:{json.dumps(iid)},title:{json.dumps(title_raw)},note:v}}}});"
        "f.note.value='';f.querySelector('.ack').textContent='queued';"
    )
    return (f'<tr class="replyrow" id="note-{esc(iid)}"><td colspan="3">'
            f'<form class="reply" data-lavish-question="todo-item-{esc(iid)}" onsubmit="{esc(js)}">'
            f'<input type="text" name="note" autocomplete="off" '
            f'placeholder="drop, done, park til Friday, mine, dig, or anything else">'
            f'<button type="submit">Queue</button><span class="ack"></span>'
            f'</form></td></tr>')

def note_toggle(rec):
    iid = esc(rec.get('_id') or '')
    js = ("var r=document.getElementById('note-" + iid + "');"
          "var o=r.classList.toggle('open');"
          "this.setAttribute('aria-expanded',o);"
          "if(o){r.querySelector('input').focus();}")
    return f'<button type="button" class="notetoggle" aria-expanded="false" onclick="{esc(js)}">note</button>'

def row(rec, reply=False):
    title = esc(rec.get('title') or 'untitled item')
    read = stamp(number(rec.get('updated')))
    severity = rec.get('class', 'obligation')
    pill = {'outage': 'bad', 'urgent': 'warn', 'deadline': 'warn'}.get(severity, 'info')
    toggle = note_toggle(rec) if reply else ''
    main = (f'<tr><td class="who"><span class="pill {pill}">{esc(severity)}</span><span class="org">{provenance(rec)}</span></td>\n'
            f'<td class="what">{title}<span class="prov obs">read {esc(read)}</span></td>\n'
            f'<td class="links">{link(rec.get("link"))}{toggle}</td></tr>')
    return main + '\n' + reply_form(rec) if reply else main

def table(rows):
    return '<div class="tablewrap"><table><tbody>\n' + '\n'.join(rows) + '\n</tbody></table></div>'

def disclosure(title, content):
    return f'<details><summary>{esc(title)}</summary>\n{content}\n</details>'

def sortkey(rec):
    return RANK.get(rec.get('class'), 99), -number(rec.get('updated')), rec.get('_id', '')

WAITING_ON_US = 'Waiting on us'

def tickets_doc():
    """Live owner-ticket snapshot, refreshed by each ticket-source read.

    Schema is version 1: read_at is the epoch of the read, and each ticket
    carries id, subject, stage and the ticket URL. An absent, unreadable,
    stale-dated or malformed file leaves the morning snapshot standing, so a
    failed refresh never silently presents itself as a live read.
    """
    path = Path(DATA) / 'tickets.json'
    if not path.is_file() or path.is_symlink():
        return None
    try:
        doc = json.loads(path.read_text())
    except ValueError:
        return None
    read = number(doc.get('read_at'))
    if doc.get('version') != 1 or not read or read > int(NOW):
        return None
    if not isinstance(doc.get('tickets'), list):
        return None
    return doc

def ticket_rows(doc):
    head = ('<tr><th>TICKET</th><th>STAGE</th><th>LAST INBOUND</th>'
            '<th>LAST OUTBOUND</th></tr>')
    body = []
    for t in doc['tickets']:
        body.append(
            '<tr><td class="what">' + esc(t.get('subject') or 'untitled ticket')
            + '</td><td>' + esc(t.get('stage') or 'unknown')
            + '</td><td>' + esc(t.get('last_in') or '-')
            + '</td><td>' + esc(t.get('last_out') or '-') + '</td></tr>')
    if not body:
        body.append('<tr><td colspan="4">No open tickets carry you as owner.</td></tr>')
    return ('<h2>Your open tickets</h2><p class="sub">Read live at '
            + esc(stamp(number(doc.get('read_at'))))
            + ', refreshed on every ticket read. Anything waiting on us is raised into '
            + 'Needs you now above rather than left here.</p>'
            + '<div class="tablewrap"><table><thead>' + head
            + '</thead><tbody>' + ''.join(body) + '</tbody></table></div>')

def ticket_actions(doc):
    """Only a ticket the customer is actually waiting on becomes an action."""
    out = []
    for t in doc['tickets']:
        if (t.get('stage') or '') != WAITING_ON_US:
            continue
        ident = str(t.get('id') or '')
        if not ident:
            continue
        out.append({'_id': 'ticket-' + ident, 'class': 'obligation',
                    'source': 'hubspot-lars-tickets', 'ref': ident,
                    'title': (t.get('subject') or 'untitled ticket')
                              + ': waiting on us since the customer wrote at '
                              + (t.get('last_in') or 'an unrecorded time'),
                    'link': t.get('link', ''), 'updated': number(doc.get('read_at'))})
    return out

items = records('items')
archived = records('archive')
# Ledger identity wins even when the latest state is waiting or archived.
ledger = {r['_id']: r for r in items + archived}
identity = {(r.get('source'), r.get('ref')): r for r in items + archived}
actions = []
reference = ''
details = ''
if MORNING:
    path = Path(MORNING)
    sidecar = path.with_suffix('.json')
    if sidecar.is_file() and not sidecar.is_symlink():
        doc = json.loads(sidecar.read_text())
        if doc.get('version') != 1 or doc.get('date') != DAY:
            raise ValueError('morning metadata must have version 1 and the rendered date')
        for raw in doc.get('actions', []):
            rec = dict(raw)
            rec['_id'] = str(rec.get('key', ''))
            read = number(rec.get('updated'))
            if (not rec['_id'] or not rec.get('source') or not rec.get('ref')
                    or rec.get('class') not in RANK or not read
                    or stamp(read, '%Y-%m-%d') != DAY or read > int(NOW)):
                raise ValueError('morning actions need key, source, ref, ranked class and same-day read epoch')
            if rec['_id'] in ledger or (rec['source'], rec['ref']) in identity:
                continue
            actions.append(rec)
        # A structured fragment contains detail only, never another document shell.
        details = path.read_text()
        if re.search(r'<(?:html|head|body|header|h1)\b', details, re.I):
            raise ValueError('structured morning HTML must be a details-only fragment')
    else:
        # Old arbitrary prose has no reliable action identity or per-item read
        # time. Never promote it to an open action or pretend a rebuild verified it.
        for section in Fragment(path.read_text()).sections():
            if re.match(r'<h2\b[^>]*>Pilot-partner connectivity\b', section, re.I):
                continue
            if re.match(r'<h2\b[^>]*>(?:Calendar|Support pipeline)\b', section, re.I):
                details += '<section class="morning-context"><p class="sub">Morning snapshot - original read times retained</p>' + section + '</section>'
            else:
                reference += section
        reference = disclosure('Earlier morning reference - not re-verified by this update',
                               '<p class="sub">Historical snapshot. Re-check sources before treating these lines as open.</p>' + reference)

TICKETS = tickets_doc()
if TICKETS is not None:
    # The morning fragment carries a frozen copy of this table; drop it so the
    # page never shows two ticket tables read at different times.
    if details:
        kept = [sec for sec in Fragment(details).sections()
                if not re.match(r'<h2\b[^>]*>\s*Your open tickets\b', sec, re.I)]
        details = ''.join(kept)
    details = ticket_rows(TICKETS) + details
    actions.extend(ticket_actions(TICKETS))

watch = {}
activity = []
waiting = []
for rec in items:
    if rec.get('state') == 'waiting':
        waiting.append(rec)
        continue
    if rec.get('state') != 'open' or rec.get('class') == 'automation-candidate':
        continue
    if rec.get('kind') == 'telemetry-fleet-alerts':
        title = rec.get('title', '')
        # Only the two enrolled fault conditions. No silence/offline classifier.
        for condition, pattern in [('B.14', r'B\.14'), ('Freezing coolers', r'coolers? under 1\s*°?\s*C|freezing')]:
            if re.search(pattern, title, re.I):
                watch.setdefault(condition, []).append(rec)
        continue
    if rec.get('class') in RANK:
        actions.append(rec)
    else:
        activity.append(rec)
# Morning duplicates must share a stable key. Sorting is deterministic on ties.
actions = list({r['_id']: r for r in actions}.values())
actions.sort(key=sortkey)
print('<h2>Needs you now<small>urgent first, newest within each priority</small></h2>')
print(table([row(r, reply=True) for r in actions]) if actions else '<div class="note"><b>Nothing open.</b> No verified action is recorded in this queue.</div>')
print('<h2>Watching<small>conditions, not additional tasks</small></h2>')
if not watch:
    print('<p class="sub">No active fleet conditions recorded.</p>')
for condition, readings in sorted(watch.items()):
    readings.sort(key=lambda r: (-number(r.get('updated')), r['_id']))
    # A full count and a later delta are different evidence. Never add reads
    # together or silently treat a delta as the current whole-fleet count.
    count_pattern = r'(\d+) active B\.14 units' if condition == 'B.14' else r'(\d+) coolers under 1\s*°?\s*C'
    count = next(((r, re.search(count_pattern, r.get('title', ''), re.I)) for r in readings
                  if re.search(count_pattern, r.get('title', ''), re.I)), None)
    summary = 'count not recorded'
    if count:
        rec, match = count
        summary = f'{match.group(1)} units at {stamp(number(rec.get("updated")))}'
    newest = readings[0]
    # Keep latest unit names/ids verbatim; the recorded total above keeps its own timestamp.
    title = newest.get('title', '')
    units = title.split('; newest:', 1)[1].strip() if '; newest:' in title else (title if re.search(r'\b\d{15}\b', title) else 'no unit detail in latest observation')
    print(f'<div class="watch-line"><b>{esc(condition)}</b> - {esc(summary)}'
          f'<span class="why">Latest: {esc(units)} · {provenance(newest)}, read {esc(stamp(number(newest.get("updated"))))} · {link(newest.get("link"))}</span></div>')
if details:
    print('<section aria-label="Tickets and calendar">' + details + '</section>')
if waiting:
    print(disclosure('Waiting on others', '<ul>' + ''.join(
        f'<li><b>{esc(r.get("title"))}</b> - {esc(r.get("resolution") or "no hand-over note recorded")}<span class="why">{provenance(r)}, handed over {esc(stamp(number(r.get("updated"))))}</span></li>'
        for r in sorted(waiting, key=sortkey)) + '</ul>'))
if activity:
    print(disclosure('Other channel activity', table([row(r) for r in sorted(activity, key=sortkey)])))
print(reference)
cleared = [r for r in archived if number(r.get('resolved_at')) and stamp(number(r['resolved_at']), '%Y-%m-%d') == DAY]
cleared.sort(key=lambda r: (-number(r.get('resolved_at')), r['_id']))
if cleared:
    rows = [f'<tr class="closed"><td>{esc(r.get("title"))}</td><td>{esc(r.get("resolution") or "no resolution recorded")}</td><td>{provenance(r)} · {esc(stamp(number(r["resolved_at"])))}</td></tr>' for r in cleared]
    print(disclosure(f'Cleared today ({len(cleared)})', table(rows)))
