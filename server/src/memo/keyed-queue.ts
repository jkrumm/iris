/**
 * Runs tasks of the same key one after another, in call order; tasks of different keys do not wait for each other.
 * A failed task does not block the next one (its error goes to its own caller only).
 */
export function createKeyedQueue(): <T>(key: string, task: () => Promise<T>) => Promise<T> {
  // The tail of each key's queue; it never rejects, and is dropped once it is the last one.
  const queues = new Map<string, Promise<void>>();

  return (key, task) => {
    const run = (queues.get(key) ?? Promise.resolve()).then(task);
    const tail = run.then(
      () => undefined,
      () => undefined,
    );
    queues.set(key, tail);
    void tail.then(() => {
      if (queues.get(key) === tail) queues.delete(key);
    });
    return run;
  };
}
