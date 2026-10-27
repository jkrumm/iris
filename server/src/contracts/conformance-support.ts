/**
 * Key-set differences between a live body and a fixture, as `path: message` lines. Values are
 * free: a `null` on either side ends the comparison there (a nullable object is absent in one
 * and present in the other), arrays compare their first elements, `freeKeys` (a schema's
 * `unknown` fields) are not entered, and `optionalKeys` (a schema's optional properties) may be
 * absent on either side.
 */
export function keyDifferences(params: {
  live: unknown;
  fixture: unknown;
  freeKeys?: readonly string[];
  optionalKeys?: readonly string[];
  path?: string;
}): string[] {
  const { live, fixture, freeKeys = ["usage"], optionalKeys = [], path = "$" } = params;
  if (live === null || fixture === null) return [];
  if (Array.isArray(live) && Array.isArray(fixture)) {
    if (live.length === 0 || fixture.length === 0) return [];
    return keyDifferences({
      live: live[0],
      fixture: fixture[0],
      freeKeys,
      optionalKeys,
      path: `${path}[0]`,
    });
  }
  const liveObject = typeof live === "object" && !Array.isArray(live);
  const fixtureObject = typeof fixture === "object" && !Array.isArray(fixture);
  if (liveObject !== fixtureObject || Array.isArray(live) !== Array.isArray(fixture)) {
    return [`${path}: live is ${describe(live)}, fixture is ${describe(fixture)}`];
  }
  if (!liveObject) return [];

  const required = (object: object) =>
    Object.keys(object)
      .filter((k) => !optionalKeys.includes(k))
      .toSorted();
  const liveKeys = required(live as object);
  const fixtureKeys = required(fixture as object);
  const problems = [
    ...liveKeys
      .filter((k) => !fixtureKeys.includes(k))
      .map((k) => `${path}.${k}: missing in fixture`),
    ...fixtureKeys
      .filter((k) => !liveKeys.includes(k))
      .map((k) => `${path}.${k}: not in live body`),
  ];
  for (const key of liveKeys.filter((k) => fixtureKeys.includes(k) && !freeKeys.includes(k))) {
    problems.push(
      ...keyDifferences({
        live: (live as Record<string, unknown>)[key],
        fixture: (fixture as Record<string, unknown>)[key],
        freeKeys,
        optionalKeys,
        path: `${path}.${key}`,
      }),
    );
  }
  return problems;
}

const describe = (value: unknown) => (Array.isArray(value) ? "an array" : typeof value);

export interface SseFrame {
  event: string;
  data: string;
}

/** The named events of an SSE stream; comment lines (keepalives) and incomplete frames are dropped. */
export function sseFrames(text: string): SseFrame[] {
  return text
    .split("\n\n")
    .map((block) => block.split("\n"))
    .flatMap((lines) => {
      const event = lines.find((l) => l.startsWith("event: "))?.slice("event: ".length);
      const data = lines.find((l) => l.startsWith("data: "))?.slice("data: ".length);
      return event !== undefined && data !== undefined ? [{ event, data }] : [];
    });
}
