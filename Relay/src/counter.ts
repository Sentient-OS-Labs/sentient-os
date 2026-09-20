// Counter: one Durable Object per key (a hashed user identity, or "global"), holding fixed-window
// counts for the current hour, day, and month. Strongly consistent by construction: a Durable
// Object runs single-threaded, so two simultaneous presses can never both slip under a cap.
// Storage is a single small record; nothing about the request itself is ever kept.

import { DurableObject } from "cloudflare:workers";

export type Window = "hour" | "day" | "month";

/** Caps per window; a missing or zero cap means "no limit on that window". */
export type Caps = Partial<Record<Window, number>>;

export type Verdict =
  | { ok: true }
  | { ok: false; window: Window; retryAfterSeconds: number };

interface State {
  hourKey: string; hour: number;
  dayKey: string; day: number;
  monthKey: string; month: number;
}

export class Counter extends DurableObject {
  /** Admit one request against `caps`, counting it if admitted. */
  async take(caps: Caps): Promise<Verdict> {
    const now = new Date();
    const iso = now.toISOString();
    const keys = { hour: iso.slice(0, 13), day: iso.slice(0, 10), month: iso.slice(0, 7) };

    const state: State = (await this.ctx.storage.get<State>("s")) ?? {
      hourKey: keys.hour, hour: 0, dayKey: keys.day, day: 0, monthKey: keys.month, month: 0,
    };
    if (state.hourKey !== keys.hour) { state.hourKey = keys.hour; state.hour = 0; }
    if (state.dayKey !== keys.day) { state.dayKey = keys.day; state.day = 0; }
    if (state.monthKey !== keys.month) { state.monthKey = keys.month; state.month = 0; }

    const over = (window: Window, count: number): Verdict | null => {
      const cap = caps[window] ?? 0;
      return cap > 0 && count >= cap
        ? { ok: false, window, retryAfterSeconds: secondsUntilNext(window, now) }
        : null;
    };
    const blocked = over("hour", state.hour) ?? over("day", state.day) ?? over("month", state.month);
    if (blocked) return blocked;

    state.hour += 1; state.day += 1; state.month += 1;
    await this.ctx.storage.put("s", state);
    return { ok: true };
  }
}

function secondsUntilNext(window: Window, now: Date): number {
  const next = new Date(now);
  if (window === "hour") {
    next.setUTCHours(now.getUTCHours() + 1, 0, 0, 0);
  } else if (window === "day") {
    next.setUTCDate(now.getUTCDate() + 1); next.setUTCHours(0, 0, 0, 0);
  } else {
    next.setUTCMonth(now.getUTCMonth() + 1, 1); next.setUTCHours(0, 0, 0, 0);
  }
  return Math.max(1, Math.ceil((next.getTime() - now.getTime()) / 1000));
}
