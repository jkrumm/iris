export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };

export function fixedClock(at: Date | string): Clock {
  const fixed = new Date(at);
  return { now: () => new Date(fixed) };
}

export interface ManualClock extends Clock {
  advance(ms: number): void;
}

/** Starts at `start` and only moves when a test calls `advance`. */
export function manualClock(start: Date | string = "2026-01-01T00:00:00.000Z"): ManualClock {
  let current = new Date(start).getTime();
  return {
    now: () => new Date(current),
    advance(ms) {
      current += ms;
    },
  };
}
