/**
 * Mirrors `ArtifactSchemeHandler.bundledPolicy`
 * (apple/Packages/IrisUI/Sources/IrisUI/Components/Artifact/ArtifactSchemeHandler.swift). The host's scheme source
 * `iris-artifact:` cannot match an http origin, so it becomes `'self'` here; every other directive is the same
 * (tests/csp.spec.ts compares the two strings).
 */
export const HOST_POLICY =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
  "font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
