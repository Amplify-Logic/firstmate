import { pathToFileURL } from "node:url";
const packageRoot = process.env.PI_PACKAGE_DIR;
const version = (await import(pathToFileURL(`${packageRoot}/package.json`).href, { with: { type: "json" } })).default.version;
const [{ ToolExecutionComponent }, { createToolHtmlRenderer }, { initTheme, theme }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`).href),
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
]);
initTheme("dark");
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");
const removeFallback = process.env.REMOVE_CALL_FALLBACK === "1";
const hadFallback = typeof ToolExecutionComponent.prototype.createCallFallback === "function";
if (removeFallback) {
  // Hide the fallback only from Firstmate's call-line probe, modelling a Pi
  // that has no createCallFallback, while Pi's own stock rows keep theirs.
  const original = ToolExecutionComponent.prototype.createCallFallback;
  Object.defineProperty(ToolExecutionComponent.prototype, "createCallFallback", {
    configurable: true,
    get() { return this.toolCallId === "fm-outcomes-call-probe" ? undefined : original; },
  });
}
const listeners = new Map(); const tools = [];
const pi = {
  events: { on(n, l) { listeners.set(n, [...(listeners.get(n) ?? []), l]); }, emit(n, d) { for (const l of listeners.get(n) ?? []) l(d); } },
  on() {}, registerCommand() {}, registerMessageRenderer() {}, registerTool(t) { tools.push(t); }, sendMessage() {}, sendUserMessage() {},
};
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
let failures = 0;
const check = (ok, msg) => { console.log(`${ok ? "PASS" : "FAIL"}: ${msg}`); if (!ok) failures++; };
console.log(`Pi ${version}; stock createCallFallback present: ${hadFallback}; removed for this run: ${removeFallback}`);
const cases = [
  ["fm_branch_processed", { through: 5 }, { content: [{ type: "text", text: "ACKNOWLEDGED_OK" }], details: undefined, isError: false }],
  ["fm_branch_outcomes", { recent: 2 }, { content: [{ type: "text", text: "OUTCOME_ONE\nOUTCOME_TWO" }], details: { ok: true }, isError: false }],
];
const ui = { requestRender() {} };
for (const [name, args, result] of cases) {
  const actualDefinition = tools.find((t) => t.name === name);
  const stockDefinition = { ...actualDefinition }; delete stockDefinition.renderShell; delete stockDefinition.renderCall; delete stockDefinition.renderResult;
  const stockRow = new ToolExecutionComponent(name, "stock", args, { showImages: false }, stockDefinition, ui, process.cwd());
  const actualRow = new ToolExecutionComponent(name, "actual", args, { showImages: false }, actualDefinition, ui, process.cwd());
  for (const row of [stockRow, actualRow]) { row.markExecutionStarted(); row.setArgsComplete(); row.updateResult(result); }
  for (const expanded of [false, true]) {
    stockRow.setExpanded(expanded); actualRow.setExpanded(expanded);
    const s = stockRow.render(80), a = actualRow.render(80);
    console.log(`\n--- ${name}(${JSON.stringify(args)}) expanded=${expanded} Calm off: Pi stock row ---`);
    console.log(s.map(stripAnsi).join("\n"));
    console.log(`--- ${name} Firstmate self-rendered row ---`);
    console.log(a.map(stripAnsi).join("\n"));
    if (removeFallback) {
      const text = a.map(stripAnsi).join("\n");
      const firstLine = text.split("\n").find((l) => l.trim()) ?? "";
      check(firstLine.trim() === name && !actualRow.render(80).join("").includes(Object.keys(args)[0]), `${name} expanded=${expanded}: missing Pi call fallback degrades to the bare '${name}' title without crashing`);
    } else {
      check(JSON.stringify(a) === JSON.stringify(s), `${name} expanded=${expanded}: self-rendered row is byte-identical to Pi's stock row`);
      const argKey = Object.keys(args)[0];
      if (version.startsWith("0.99")) check(stripAnsi(a.join("\n")).includes(argKey), `${name} expanded=${expanded}: call line shows the '${argKey}' argument like Pi 0.99 stock`);
    }
  }
  pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: false });
  actualRow.invalidate();
  check(actualRow.render(80).length === 0, `${name}: Calm on hides the whole row (0 lines)`);
  pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
  actualRow.invalidate();
  if (!removeFallback) check(JSON.stringify(actualRow.render(80)) === JSON.stringify(stockRow.render(80)), `${name}: Calm off again restores the stock-identical row`);
  pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: true });
  const html = createToolHtmlRenderer({ getToolDefinition: () => actualDefinition, theme, cwd: process.cwd() });
  check(html.renderCall("h", name, args) === undefined && html.renderResult("h", name, result.content, result.details, false) === undefined, `${name}: HTML export falls through to Pi's structured fallback`);
  pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
}
console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures ? 1 : 0);
