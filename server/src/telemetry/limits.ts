/** Largest `POST /telemetry` body; the clients flush every 10 s, so a batch is far below it. */
export const TELEMETRY_MAX_BYTES = 256 * 1024;

/** Most spans plus logs one `POST /telemetry` batch may carry. */
export const TELEMETRY_MAX_RECORDS = 500;
