import { Elysia } from "elysia";
import { configured } from "../memo/errors.js";
import type { FactoryService } from "../factory/service.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, FactoryAnswerBody, FactoryAnswerResponse, FactoryResponse } from "./schemas.js";

/**
 * `GET /factory`: the software factory's asks and health line. `POST /factory/answer`: forwards an answer to a decision ask.
 * Both 503 `unavailable` when the factory is unconfigured or unreachable.
 */
export function factoryRoutes(deps: {
  factory: FactoryService | undefined;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { factory, auth } = deps;

  return new Elysia()
    .use(auth)
    .get("/factory", () => configured(factory, "factory").view(), {
      response: { 200: FactoryResponse, 503: ErrorBody },
    })
    .post("/factory/answer", ({ body }) => configured(factory, "factory").answer(body), {
      body: FactoryAnswerBody,
      response: {
        200: FactoryAnswerResponse,
        400: ErrorBody,
        404: ErrorBody,
        409: ErrorBody,
        503: ErrorBody,
      },
    });
}
