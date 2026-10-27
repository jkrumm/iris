import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Credentials for tests, generated on the spot: nothing secret-shaped is ever committed.

const toPem = (label: string, der: ArrayBuffer) =>
  `-----BEGIN ${label}-----\n${Buffer.from(der)
    .toString("base64")
    .replace(/(.{64})/g, "$1\n")}\n-----END ${label}-----\n`;

/** An ES256 provider key like Apple's `.p8`: the PKCS#8 PEM plus the public key to verify JWTs with. */
export async function generateP8() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  return { pem: toPem("PRIVATE KEY", pkcs8), publicKey: pair.publicKey };
}

/** A self-signed localhost certificate from the `openssl` CLI, or null when it is not installed. */
export async function generateLocalhostCert(): Promise<{ key: string; cert: string } | null> {
  const dir = await mkdtemp(join(tmpdir(), "iris-apns-cert-"));
  try {
    const proc = Bun.spawn(
      [
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:prime256v1",
        "-nodes",
        "-days",
        "1",
        "-subj",
        "/CN=localhost",
        "-addext",
        "subjectAltName=DNS:localhost,IP:127.0.0.1",
        "-keyout",
        join(dir, "key.pem"),
        "-out",
        join(dir, "cert.pem"),
      ],
      { stdout: "ignore", stderr: "ignore" },
    );
    if ((await proc.exited) !== 0) return null;
    return {
      key: await readFile(join(dir, "key.pem"), "utf8"),
      cert: await readFile(join(dir, "cert.pem"), "utf8"),
    };
  } catch {
    return null;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

const base64urlToBytes = (value: string) => new Uint8Array(Buffer.from(value, "base64url"));

/** Decodes an APNs `authorization: bearer` JWT and verifies its raw r||s ES256 signature. */
export async function verifyBearerJwt(authorization: string, publicKey: CryptoKey) {
  const jwt = authorization.replace(/^bearer /, "");
  const [header = "", claims = "", signature = ""] = jwt.split(".");
  const signatureBytes = base64urlToBytes(signature);
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signatureBytes,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  return {
    header: JSON.parse(Buffer.from(header, "base64url").toString()) as Record<string, unknown>,
    claims: JSON.parse(Buffer.from(claims, "base64url").toString()) as Record<string, unknown>,
    signatureBytes: signatureBytes.length,
    verified,
  };
}
