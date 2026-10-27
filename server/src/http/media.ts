import { Elysia } from "elysia";
import { configured } from "../memo/errors.js";
import type { MemoMedia } from "../memo/media.js";
import type { Recording } from "../ports/audio.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, MemoIdParams } from "./schemas.js";

// Building the recording or synthesizing speech can outlast Bun's 10 s idle timeout, which counts
// silence on the socket. Bun accepts at most 255 seconds.
const BUILD_TIMEOUT_SECONDS = 120;

type ByteRange = { start: number; end: number };

/**
 * One `bytes=` range against a body of `size` bytes, ends inclusive. Null means "serve the whole
 * body": no header, a malformed or multi-range one (RFC 9110 lets a server ignore those).
 * "unsatisfiable" is a well-formed range that starts past the end (416).
 */
export function parseRange(
  header: string | null,
  size: number,
): ByteRange | "unsatisfiable" | null {
  const match = header ? /^bytes=(\d*)-(\d*)$/.exec(header.trim()) : null;
  if (!match) return null;
  const [, first = "", last = ""] = match;
  if (first === "" && last === "") return null;
  if (first === "") {
    const suffix = Number(last);
    if (suffix === 0 || size === 0) return "unsatisfiable";
    return { start: Math.max(size - suffix, 0), end: size - 1 };
  }
  const start = Number(first);
  if (start >= size) return "unsatisfiable";
  const end = last === "" ? size - 1 : Math.min(Number(last), size - 1);
  return end < start ? null : { start, end };
}

/** 200 whole, 206 with `Content-Range`, or 416, always advertising `Accept-Ranges`. */
function rangedResponse(params: { request: Request; body: Recording; type: string }): Response {
  const { request, body, type } = params;
  const { size } = body;
  const base = { "content-type": type, "accept-ranges": "bytes" };
  const range = parseRange(request.headers.get("range"), size);

  if (range === "unsatisfiable") {
    return new Response(null, {
      status: 416,
      headers: { ...base, "content-range": `bytes */${size}` },
    });
  }
  if (!range) {
    return new Response(body.slice(0, size), {
      headers: { ...base, "content-length": String(size) },
    });
  }
  return new Response(body.slice(range.start, range.end + 1), {
    status: 206,
    headers: {
      ...base,
      "content-length": String(range.end - range.start + 1),
      "content-range": `bytes ${range.start}-${range.end}/${size}`,
    },
  });
}

/** `GET /memos/:id/audio` (range-aware, for AVPlayer scrubbing) and `GET /memos/:id/speech`. */
export function mediaRoutes(deps: {
  media: MemoMedia | undefined;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { media, auth } = deps;
  const errors = { 404: ErrorBody, 409: ErrorBody, 503: ErrorBody };

  return new Elysia({ prefix: "/memos" })
    .use(auth)
    .get(
      "/:id/audio",
      async ({ params, request, server }) => {
        server?.timeout(request, BUILD_TIMEOUT_SECONDS);
        const body = await configured(media, "media").recording(params.id);
        return rangedResponse({ request, body, type: "audio/mp4" });
      },
      { params: MemoIdParams, response: errors },
    )
    .get(
      "/:id/speech",
      async ({ params, request, server }) => {
        server?.timeout(request, BUILD_TIMEOUT_SECONDS);
        const bytes = await configured(media, "media").speech(params.id);
        return new Response(bytes, {
          headers: { "content-type": "audio/mpeg", "content-length": String(bytes.byteLength) },
        });
      },
      { params: MemoIdParams, response: errors },
    );
}
