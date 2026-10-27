import type { Database } from "bun:sqlite";
import type { Clock } from "../ports/clock.js";
import type { ApnsEnv, Device, DeviceStore, Platform } from "../ports/devices.js";
import { migrate } from "./sqlite.js";

interface DeviceRow {
  device: string;
  name: string;
  platform: string;
  apns_token: string | null;
  apns_env: string | null;
  push_to_start_token: string | null;
  last_seen_at: string;
  updated_at: string;
}

const toDevice = (row: DeviceRow): Device => ({
  device: row.device,
  name: row.name,
  platform: row.platform as Platform,
  apnsToken: row.apns_token,
  apnsEnv: row.apns_env as ApnsEnv | null,
  pushToStartToken: row.push_to_start_token,
  lastSeenAt: row.last_seen_at,
  updatedAt: row.updated_at,
});

/** `undefined` and "" keep the stored value; only an explicit `null` clears it. */
const merge = <T extends string>(incoming: T | null | undefined, stored: T | null): T | null =>
  incoming === undefined || incoming === "" ? stored : incoming;

/** Devices and Live Activity tokens over the same database as the memo store. */
export function createSqliteDeviceStore(params: { db: Database; clock: Clock }): DeviceStore {
  const { db, clock } = params;
  db.exec("PRAGMA foreign_keys = ON");
  migrate(db);

  const deviceById = (device: string) =>
    db.query<DeviceRow, [string]>("SELECT * FROM devices WHERE device = ?").get(device);

  const register = db.transaction((input: Parameters<DeviceStore["registerDevice"]>[0]) => {
    const { device, name, platform } = input;
    const stored = deviceById(device);
    const at = clock.now().toISOString();
    db.query(
      `INSERT INTO devices
         (device, name, platform, apns_token, apns_env, push_to_start_token, last_seen_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (device) DO UPDATE SET
         name = excluded.name, platform = excluded.platform, apns_token = excluded.apns_token,
         apns_env = excluded.apns_env, push_to_start_token = excluded.push_to_start_token,
         last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at`,
    ).run(
      device,
      name,
      platform,
      merge(input.apnsToken, stored?.apns_token ?? null),
      merge<ApnsEnv>(input.apnsEnv, (stored?.apns_env as ApnsEnv | null) ?? null),
      merge(input.pushToStartToken, stored?.push_to_start_token ?? null),
      at,
      at,
    );
    return toDevice(deviceById(device) as DeviceRow);
  });

  return {
    registerDevice: (input) => register(input),

    getDevice(device) {
      const row = deviceById(device);
      return row ? toDevice(row) : null;
    },

    clearApnsToken({ device, expected }) {
      const { changes } = db
        .query("UPDATE devices SET apns_token = NULL WHERE device = ? AND apns_token = ?")
        .run(device, expected);
      return changes > 0;
    },

    listDevices() {
      return db.query<DeviceRow, []>("SELECT * FROM devices ORDER BY rowid").all().map(toDevice);
    },

    setActivityToken({ memoId, token }) {
      const exists = db.query("SELECT 1 FROM memos WHERE id = ?").get(memoId);
      if (!exists) return false;
      db.query(
        `INSERT INTO activity_tokens (memo_id, token, updated_at) VALUES (?, ?, ?)
         ON CONFLICT (memo_id) DO UPDATE SET token = excluded.token, updated_at = excluded.updated_at`,
      ).run(memoId, token, clock.now().toISOString());
      return true;
    },

    getActivityToken(memoId) {
      return (
        db
          .query<{ token: string }, [string]>("SELECT token FROM activity_tokens WHERE memo_id = ?")
          .get(memoId)?.token ?? null
      );
    },

    clearActivityToken(memoId) {
      db.query("DELETE FROM activity_tokens WHERE memo_id = ?").run(memoId);
    },
  };
}
