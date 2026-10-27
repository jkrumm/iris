import { Elysia } from "elysia";
import { configured } from "../memo/errors.js";
import type { MemoService } from "../memo/service.js";
import type { DeviceStore } from "../ports/devices.js";
import type { deviceAuth } from "./auth.js";
import {
  ActivityTokenBody,
  Device,
  ErrorBody,
  MemoIdParams,
  RegisterDeviceBody,
} from "./schemas.js";
import { deviceJson } from "./serialize.js";

/**
 * `POST /devices/register` and `PUT /memos/:id/activity-token`. Identity is always the
 * authenticated device, never a body field.
 */
export function deviceRoutes(deps: {
  devices: DeviceStore | undefined;
  memos: MemoService;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { devices, memos, auth } = deps;

  return new Elysia()
    .use(auth)
    .post(
      "/devices/register",
      ({ body, device }) =>
        deviceJson(
          configured(devices, "devices").registerDevice({
            device: device as string,
            name: body.name,
            platform: body.platform,
            apnsToken: body.apnsToken,
            apnsEnv: body.apnsEnv,
            pushToStartToken: body.pushToStartToken,
          }),
        ),
      {
        body: RegisterDeviceBody,
        response: { 200: Device, 400: ErrorBody, 503: ErrorBody },
      },
    )
    .put(
      "/memos/:id/activity-token",
      ({ params, body, set }) => {
        const store = configured(devices, "devices");
        memos.get(params.id); // 404 for an unknown memo
        store.setActivityToken({ memoId: params.id, token: body.token });
        set.status = 204;
      },
      {
        params: MemoIdParams,
        body: ActivityTokenBody,
        response: { 400: ErrorBody, 404: ErrorBody, 503: ErrorBody },
      },
    );
}
