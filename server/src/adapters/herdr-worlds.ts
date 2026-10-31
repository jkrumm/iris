import { TabGoneError, type Destination } from "../ports/destination.js";
import type { Herd } from "../ports/herd.js";

// Both herdr worlds at once until classic herdr is retired (dotfiles `docs/waves/PLAN.md`, Wave 7). The destination
// value stays `"herdr"`; a tab id says which world it belongs to (hc: the `herdr.tab` label, classic: `w2:t1`).
// TODO(Wave 7): drop classic: `herdr.ts`, `HERDR_SOCKET`, and this file collapses to the hc adapters.

/**
 * `GET /herd` lists every world, hc first. It fails (`unavailable`) when ANY configured world fails: routing resolves
 * a spoken or mode `tab` against this list ("the only live tab"), and a list missing a world's tabs would pick the
 * wrong agent.
 */
export function mergeHerds(herds: readonly Herd[]): Herd {
  return {
    async snapshot() {
      return (await Promise.all(herds.map((h) => h.snapshot()))).flat();
    },
  };
}

/**
 * Delivers to a matching hc terminal when there is one, else through classic. A classic delivery is tried when hc does
 * not know the tab (`TabGoneError`) or cannot be reached; if classic does not know it either, hc's own error stands,
 * so an hc failure is never rewritten into "the tab is gone".
 */
export function preferHc(params: { hc: Destination; classic: Destination }): Destination {
  const { hc, classic } = params;
  return {
    async deliver(delivery) {
      try {
        return await hc.deliver(delivery);
      } catch (hcError) {
        try {
          return await classic.deliver(delivery);
        } catch (classicError) {
          if (classicError instanceof TabGoneError) throw hcError;
          throw classicError;
        }
      }
    },
  };
}
