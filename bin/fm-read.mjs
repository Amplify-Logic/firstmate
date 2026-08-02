#!/usr/bin/env node
// Self-contained Markdown-to-HTML renderer for fm-read.sh.
// It intentionally escapes raw HTML and supports the report-oriented Markdown
// surface used by Firstmate: headings, paragraphs, emphasis, links, images,
// blockquotes, lists, fenced code, rules, and pipe tables.
import fs from "node:fs";
import path from "node:path";

const [source, output] = process.argv.slice(2);
if (!source || !output) {
  console.error("usage: fm-read.mjs <source.md> <output.html>");
  process.exit(2);
}

const escapeHtml = (value) => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

function inline(value) {
  const code = [];
  let text = value.replace(/`([^`]+)`/g, (_match, body) => {
    code.push(`<code>${escapeHtml(body)}</code>`);
    return `\u0000CODE${code.length - 1}\u0000`;
  });
  text = escapeHtml(text);
  text = text.replace(/!\[([^\]]*)\]\(([^\s)]+)(?:\s+&quot;([^&]*)&quot;)?\)/g,
    (_match, alt, href, title) => `<img src="${href}" alt="${alt}"${title ? ` title="${title}"` : ""}>`);
  text = text.replace(/\[([^\]]+)\]\(([^\s)]+)(?:\s+&quot;([^&]*)&quot;)?\)/g,
    (_match, label, href, title) => `<a href="${href}"${title ? ` title="${title}"` : ""}>${label}</a>`);
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/__([^_]+)__/g, "<strong>$1</strong>");
  text = text.replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>");
  text = text.replace(/(^|[^_])_([^_]+)_/g, "$1<em>$2</em>");
  text = text.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  return text.replace(/\u0000CODE(\d+)\u0000/g, (_match, index) => code[Number(index)]);
}

function tableCells(line) {
  let value = line.trim();
  if (value.startsWith("|")) value = value.slice(1);
  if (value.endsWith("|")) value = value.slice(0, -1);
  return value.split(/(?<!\\)\|/).map((cell) => cell.trim().replaceAll("\\|", "|"));
}

function isTableDivider(line) {
  const cells = tableCells(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function render(markdown) {
  const lines = markdown.replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  const out = [];
  let paragraph = [];
  let listType = "";
  let quote = [];

  const flushParagraph = () => {
    if (paragraph.length) out.push(`<p>${inline(paragraph.join(" ").trim())}</p>`);
    paragraph = [];
  };
  const closeList = () => {
    if (listType) out.push(`</${listType}>`);
    listType = "";
  };
  const flushQuote = () => {
    if (quote.length) out.push(`<blockquote>${render(quote.join("\n"))}</blockquote>`);
    quote = [];
  };
  const flushBlocks = () => {
    flushParagraph();
    closeList();
    flushQuote();
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const fence = line.match(/^\s*```([^`]*)$/);
    if (fence) {
      flushBlocks();
      const body = [];
      i += 1;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      const language = fence[1].trim().replace(/[^A-Za-z0-9_-]/g, "");
      out.push(`<pre><code${language ? ` class="language-${language}"` : ""}>${escapeHtml(body.join("\n"))}</code></pre>`);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      flushBlocks();
      const level = heading[1].length;
      out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      continue;
    }
    if (i + 1 < lines.length && line.includes("|") && isTableDivider(lines[i + 1])) {
      flushBlocks();
      const headers = tableCells(line);
      const alignments = tableCells(lines[i + 1]).map((cell) => cell.startsWith(":") && cell.endsWith(":") ? "center" : cell.endsWith(":") ? "right" : "left");
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim()) {
        rows.push(tableCells(lines[i]));
        i += 1;
      }
      i -= 1;
      out.push("<div class=\"tw\"><table><thead><tr>");
      headers.forEach((cell, index) => out.push(`<th style="text-align:${alignments[index] || "left"}">${inline(cell)}</th>`));
      out.push("</tr></thead><tbody>");
      rows.forEach((row) => {
        out.push("<tr>");
        headers.forEach((_cell, index) => out.push(`<td style="text-align:${alignments[index] || "left"}">${inline(row[index] || "")}</td>`));
        out.push("</tr>");
      });
      out.push("</tbody></table></div>");
      continue;
    }
    if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      flushBlocks();
      out.push("<hr>");
      continue;
    }
    const quoteLine = line.match(/^>\s?(.*)$/);
    if (quoteLine) {
      flushParagraph();
      closeList();
      quote.push(quoteLine[1]);
      continue;
    }
    if (quote.length) flushQuote();
    const unordered = line.match(/^\s*[-+*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (unordered || ordered) {
      flushParagraph();
      const nextType = unordered ? "ul" : "ol";
      if (listType !== nextType) {
        closeList();
        listType = nextType;
        out.push(`<${listType}>`);
      }
      out.push(`<li>${inline((unordered || ordered)[1])}</li>`);
      continue;
    }
    if (!line.trim()) {
      flushBlocks();
      continue;
    }
    if (listType) closeList();
    paragraph.push(line.trim());
  }
  flushBlocks();
  return out.join("\n");
}

const markdown = fs.readFileSync(source, "utf8");
const body = render(markdown);
const title = escapeHtml(path.basename(source, path.extname(source)).replaceAll("-", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()));
const css = `
:root{--ink:#f2efe9;--dim:#a9a394;--line:#2b2f3a;--bg:#0e1116;--card:#161a22;--accent:#7aa7ff}
@media (prefers-color-scheme:light){:root{--ink:#1a1c20;--dim:#5d6470;--line:#e2dfd8;--bg:#fbfaf7;--card:#fff;--accent:#2f5fd0}}
:root[data-theme="dark"]{--ink:#f2efe9;--dim:#a9a394;--line:#2b2f3a;--bg:#0e1116;--card:#161a22;--accent:#7aa7ff}
:root[data-theme="light"]{--ink:#1a1c20;--dim:#5d6470;--line:#e2dfd8;--bg:#fbfaf7;--card:#fff;--accent:#2f5fd0}
*{box-sizing:border-box}html{overflow-x:hidden}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.72 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,sans-serif;overflow-wrap:anywhere}
main{max-width:820px;margin:0 auto;padding:52px 24px 110px;min-width:0}h1,h2,h3,h4,h5,h6{line-height:1.34;padding-bottom:4px}
h1{font-size:2.3rem;letter-spacing:-.4px;margin:0 0 22px}h2{font-size:1.5rem;margin:46px 0 12px;letter-spacing:-.2px;border-bottom:1px solid var(--line);padding-top:6px}
h3{font-size:1.14rem;margin:30px 0 8px}h4,h5,h6{font-size:1rem;margin:22px 0 6px;color:var(--dim);text-transform:uppercase;letter-spacing:.6px}
p,li{max-width:74ch}p{margin:0 0 15px}ul,ol{padding-left:22px;margin:0 0 15px}li{margin-bottom:7px}strong{font-weight:680}a{color:var(--accent)}
hr{border:0;border-top:1px solid var(--line);margin:40px 0}blockquote{margin:16px 0;padding:2px 0 2px 18px;border-left:3px solid var(--accent);color:var(--dim)}
code{background:rgba(127,127,127,.16);padding:1px 6px;border-radius:5px;font-size:.87em;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-word}
pre{max-width:100%;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:15px 17px;overflow-x:auto;margin:16px 0;line-height:1.55}pre code{background:none;padding:0;font-size:.85rem;word-break:normal}
.tw{max-width:100%;overflow-x:auto;margin:18px 0;border:1px solid var(--line);border-radius:10px}table{border-collapse:collapse;width:100%;min-width:420px;font-size:.95rem}
th,td{text-align:left;padding:11px 15px;border-bottom:1px solid var(--line);vertical-align:top}th{background:rgba(127,127,127,.09);font-size:.79rem;text-transform:uppercase;letter-spacing:.5px;color:var(--dim)}tr:last-child td{border-bottom:0}img{max-width:100%;height:auto}
`;
const html = `<!doctype html>\n<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>${css}</style></head><body><main>\n${body}\n</main></body></html>\n`;
fs.writeFileSync(output, html);
