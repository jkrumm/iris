export const PLATFORMS = ["ios", "macos"] as const;
export type Platform = (typeof PLATFORMS)[number];

export const APNS_ENVS = ["sandbox", "production"] as const;
export type ApnsEnv = (typeof APNS_ENVS)[number];

/** A registered client. `device` is the authenticated name from the token map; `name` is a display label. */
export interface Device {
  device: string;
  name: string;
  platform: Platform;
  apnsToken: string | null;
  apnsEnv: ApnsEnv | null;
  pushToStartToken: string | null;
  lastSeenAt: string;
  updatedAt: string;
}

/** Synchronous like MemoStore: the one adapter is bun:sqlite over the same database. */
export interface DeviceStore {
  /**
   * Upsert by `device`. For each token field, `undefined` or an empty string keeps the stored
   * value and only an explicit `null` clears it. Stamps `lastSeenAt`.
   */
  registerDevice(params: {
    device: string;
    name: string;
    platform: Platform;
    apnsToken?: string | null | undefined;
    apnsEnv?: ApnsEnv | null | undefined;
    pushToStartToken?: string | null | undefined;
  }): Device;
  getDevice(device: string): Device | null;
  /** Oldest registration first. */
  listDevices(): Device[];

  /** Replaces the memo's Live Activity push token (it can rotate mid-activity); false for an unknown memo. */
  setActivityToken(params: { memoId: string; token: string }): boolean;
  getActivityToken(memoId: string): string | null;
}
