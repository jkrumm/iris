/** A caller gave up waiting for the tasks ahead of it on its key; the task it queued never runs. */
export class KeyedQueueTimeout extends Error {
  constructor(
    readonly key: string,
    readonly waitedMs: number,
    readonly ahead: string,
  ) {
    super(`thread ${key} is busy: waited ${waitedMs} ms behind ${ahead}, which has not finished`);
    this.name = "KeyedQueueTimeout";
  }
}

/** Waits `ms`, or settles early once `signal` aborts: the queue aborts it when the turn ahead wins, so no timer is left behind. */
export type CancellableSleep = (ms: number, signal: AbortSignal) => Promise<void>;

const timerSleep: CancellableSleep = (ms, signal) =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });

export interface KeyedQueueOptions {
  /** How long a caller waits for the tasks ahead of it on its key; unbounded when absent. A task that has started always runs to its end. */
  maxWaitMs?: number;
  /** Times that wait; tests inject an instant or manual one. */
  sleep?: CancellableSleep;
}

/** Runs `task` after everything queued before it on `key`; `label` names this task in a later caller's timeout. */
export type KeyedQueue = <T>(key: string, task: () => Promise<T>, label?: string) => Promise<T>;

/**
 * Runs tasks of the same key one after another, in call order; tasks of different keys do not wait for each other.
 * A failed task does not block the next one (its error goes to its own caller only).
 *
 * With `maxWaitMs` a caller that is still queued after that long rejects with `KeyedQueueTimeout` naming the oldest
 * unfinished task ahead of it, and its own task never runs. Its place in line stays until the task ahead finishes, so
 * a later caller still waits for that task and the stuck one's eventual completion does not disturb anyone.
 */
export function createKeyedQueue(opts: KeyedQueueOptions = {}): KeyedQueue {
  const { maxWaitMs, sleep = timerSleep } = opts;
  // Per key: the tail of its line (never rejects), and the labels of the tasks that have not finished, oldest first.
  const lines = new Map<string, { tail: Promise<void>; pending: { label: string }[] }>();

  return function enqueue<T>(key: string, task: () => Promise<T>, label = key): Promise<T> {
    const line = lines.get(key);
    const entry = { label };
    const prev = line?.tail;
    const pending = line?.pending ?? [];
    pending.push(entry);

    let run: Promise<T>;
    if (prev === undefined) {
      run = Promise.resolve().then(task);
    } else if (maxWaitMs === undefined) {
      run = prev.then(task);
    } else {
      const timer = new AbortController();
      run = Promise.race([
        prev.then(() => "turn" as const),
        sleep(maxWaitMs, timer.signal).then(() => "timeout" as const),
      ]).then((winner) => {
        timer.abort();
        if (winner === "timeout") {
          const ahead = pending.find((other) => other !== entry)?.label ?? key;
          throw new KeyedQueueTimeout(key, maxWaitMs, ahead);
        }
        return task();
      });
    }

    // Chained behind `prev`, not just behind this run: a caller that timed out settles early, but the task it
    // waited on has not finished, so whoever queues next must still wait for it.
    const settled = run.then(
      () => undefined,
      () => undefined,
    );
    const tail = prev === undefined ? settled : prev.then(() => settled);
    lines.set(key, { tail, pending });
    void tail.then(() => {
      pending.splice(pending.indexOf(entry), 1);
      if (lines.get(key)?.tail === tail) lines.delete(key);
    });
    return run;
  };
}
