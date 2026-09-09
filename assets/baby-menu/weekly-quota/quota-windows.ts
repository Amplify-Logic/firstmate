// Codex allowance-window classification, kept in its own dependency-free module
// so it can be exercised against recorded provider payloads without the app.
//
// The rule this module exists to enforce: a window is identified by what the
// provider says it IS - its own declared length, or a semantic name - never by
// where it appears in the response. The Codex payload carries `primary_window`
// and `secondary_window`, and which of those is the 5-hour window varies by
// account and by plan. Some accounts publish only one window at all. Reading
// position as meaning produced a real mislabel: a lone 7-day window rendered as
// "SESSION" with a 6d23h countdown, which reads as a five-hour limit that has
// somehow not reset in a week.
//
// An unrecognised window keeps its own honest duration label rather than being
// forced into the nearest known bucket, and a window with no usable duration
// says so.

export type RawCodexWindow = {
  used_percent?: unknown;
  limit_window_seconds?: unknown;
  reset_at?: unknown;
  // Optional semantic identity, when the provider supplies one. Positional keys
  // are deliberately NOT accepted here.
  name?: unknown;
  kind?: unknown;
  window_type?: unknown;
};

export type ClassifiedWindow = {
  id: string;
  label: string;
  percentUsed: number;
  resetAt?: string;
  // The duration the classification was based on, in seconds, when the provider
  // declared one. Absent means the window's length is unknown.
  windowSeconds?: number;
  // false when neither a declared length nor a semantic name matched a known
  // allowance window, so the label describes the window rather than naming it.
  recognized: boolean;
};

type KnownWindow = { id: string; label: string; seconds: number; names: string[] };

// The two allowance windows Codex publishes today. Both are matched by their own
// declared length first; the name list is a fallback for payloads that name a
// window without declaring its length.
const KNOWN_WINDOWS: KnownWindow[] = [
  { id: "five_hour", label: "SESSION", seconds: 18000, names: ["5h", "five_hour", "fivehour", "session", "short"] },
  { id: "weekly", label: "WEEKLY", seconds: 604800, names: ["7d", "seven_day", "sevenday", "weekly", "week"] },
];

// Providers round and occasionally re-cut a window slightly; 10% of the window's
// own length is wide enough for that and far too narrow to swallow a different
// window (18000s and 604800s are a factor of 33 apart).
const RELATIVE_TOLERANCE = 0.1;

function finiteNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isFinite(number) ? number : null;
}

function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, value));
}

function semanticName(raw: RawCodexWindow): string | null {
  for (const value of [raw.name, raw.kind, raw.window_type]) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim().toLowerCase();
  }
  return null;
}

function matchByDuration(seconds: number): KnownWindow | null {
  for (const known of KNOWN_WINDOWS) {
    if (Math.abs(seconds - known.seconds) <= known.seconds * RELATIVE_TOLERANCE) return known;
  }
  return null;
}

function matchByName(name: string): KnownWindow | null {
  const normalized = name.replace(/[\s-]+/g, "_");
  for (const known of KNOWN_WINDOWS) {
    if (known.names.some((candidate) => normalized === candidate || normalized.includes(candidate))) return known;
  }
  return null;
}

// A window whose length is declared but unfamiliar is described by that length,
// so the panel never implies it is one of the windows above.
export function describeDuration(seconds: number): string {
  if (seconds <= 0) return "WINDOW";
  if (seconds % 86400 === 0) return `${String(seconds / 86400)}D WINDOW`;
  if (seconds % 3600 === 0) return `${String(seconds / 3600)}H WINDOW`;
  if (seconds % 60 === 0) return `${String(seconds / 60)}M WINDOW`;
  return `${String(seconds)}S WINDOW`;
}

/**
 * Classify Codex allowance windows by their own identity.
 *
 * Each window is judged on its own; no window's meaning depends on another
 * window being present, on response order, or on the `primary`/`secondary` key
 * it arrived under. A known window is claimed at most once, so two windows of
 * the same length cannot both render as SESSION - the second keeps its duration
 * label instead. Output is ordered shortest window first, with windows of
 * unknown length last, so the limit that bites soonest reads first.
 */
export function classifyCodexWindows(rawWindows: readonly RawCodexWindow[]): ClassifiedWindow[] {
  const claimed = new Set<string>();
  const classified: ClassifiedWindow[] = [];

  for (let index = 0; index < rawWindows.length; index += 1) {
    const raw = rawWindows[index];
    const percentUsed = finiteNumber(raw.used_percent);
    if (percentUsed === null) continue;

    const seconds = finiteNumber(raw.limit_window_seconds);
    const name = semanticName(raw);
    const known =
      (seconds !== null && seconds > 0 ? matchByDuration(seconds) : null) ?? (name ? matchByName(name) : null);

    const resetAtSeconds = finiteNumber(raw.reset_at);
    const resetAt =
      resetAtSeconds !== null ? new Date(resetAtSeconds * 1000).toISOString() : undefined;

    if (known && !claimed.has(known.id)) {
      claimed.add(known.id);
      classified.push({
        id: known.id,
        label: known.label,
        percentUsed: clampPercent(percentUsed),
        resetAt,
        windowSeconds: seconds !== null && seconds > 0 ? seconds : known.seconds,
        recognized: true,
      });
      continue;
    }

    if (seconds !== null && seconds > 0) {
      classified.push({
        id: `window_${String(seconds)}s`,
        label: describeDuration(seconds),
        percentUsed: clampPercent(percentUsed),
        resetAt,
        windowSeconds: seconds,
        recognized: false,
      });
      continue;
    }

    // No declared length and no name we recognise: say the length is unknown
    // rather than guessing which allowance this is.
    classified.push({
      id: `window_unknown_${String(index + 1)}`,
      label: "WINDOW (LENGTH UNKNOWN)",
      percentUsed: clampPercent(percentUsed),
      resetAt,
      recognized: false,
    });
  }

  return classified.sort((a, b) => {
    if (a.windowSeconds === undefined && b.windowSeconds === undefined) return 0;
    if (a.windowSeconds === undefined) return 1;
    if (b.windowSeconds === undefined) return -1;
    return a.windowSeconds - b.windowSeconds;
  });
}
