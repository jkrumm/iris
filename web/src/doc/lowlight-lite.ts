// rehype-highlight imports `common` (37 languages) as the default of its `languages` option, which keeps
// all of them in the bundle even though we always pass our own subset. This stand-in (see vite.config.ts alias)
// keeps `createLowlight` and drops the default set.
export { createLowlight } from "../../node_modules/lowlight/lib/index.js";
export const common = {};
