import { appendFileSync } from "node:fs";
export default function (pi: any) {
  const log = process.env.PROBE_LOG!;
  let triggered = false;
  pi.on("before_agent_start", (event: any) => {
    appendFileSync(log, JSON.stringify({
      keys: Object.keys(event).sort(),
      messageType: "messageType" in event ? event.messageType : "<absent>",
      hasPromptKey: "prompt" in event,
      prompt: event.prompt,
      hasMessageKey: "message" in event,
      message: event.message ? { role: event.message.role, customType: event.message.customType, content: event.message.content } : undefined,
    }) + "\n");
  });
  pi.on("agent_end", () => {
    if (triggered) return;
    triggered = true;
    setTimeout(() => pi.sendMessage({ customType: "fm-branch-process", content: "probe processing request", display: false }, { triggerTurn: true }), 1000);
  });
}
