import type { MemoEvent } from "../memo/events.js";
import {
  isTyped,
  type Memo,
  type StepRecord,
  type Thread,
  type ThreadMessage,
} from "../memo/memo.js";
import type { MemoDetail, ThreadDetail } from "../memo/service.js";
import type { Device } from "../ports/devices.js";

// The wire format is camelCase (docs/TDD.md §3). Every response shape is spelled out here, in
// the one file, so a domain rename can never change a contract by accident.

export const memoJson = (memo: Memo) => ({
  id: memo.id,
  mode: memo.mode,
  device: memo.device,
  startedAt: memo.startedAt,
  state: memo.state,
  failedStep: memo.failedStep,
  error: memo.error,
  segmentCount: memo.segmentCount,
  audioSeconds: memo.audioSeconds,
  transcript: memo.transcript,
  route: memo.route,
  destinationRef: memo.destinationRef,
  replyText: memo.replyText,
  summary: memo.summary,
  ...(memo.threadId !== null && { threadId: memo.threadId }),
  ...(isTyped(memo) && { typed: true as const }),
  ...(memo.routeReason !== undefined && { routeReason: memo.routeReason }),
  ...(memo.routeSuggestion !== undefined && { routeSuggestion: memo.routeSuggestion }),
  createdAt: memo.createdAt,
  updatedAt: memo.updatedAt,
});

const stepJson = (record: StepRecord) => ({
  step: record.step,
  status: record.status,
  startedAt: record.startedAt,
  finishedAt: record.finishedAt,
  error: record.error,
  usage: record.usage,
  costUsd: record.costUsd,
});

export const detailJson = ({ memo, steps, segmentCount }: MemoDetail) => ({
  ...memoJson(memo),
  segmentCount,
  steps: steps.map(stepJson),
});

export const threadJson = (thread: Thread) => ({
  id: thread.id,
  kind: thread.kind,
  title: thread.title,
  createdAt: thread.createdAt,
  updatedAt: thread.updatedAt,
  lastMemoId: thread.lastMemoId,
});

const messageJson = (message: ThreadMessage) => ({
  memoId: message.memoId,
  role: message.role,
  content: message.content,
  createdAt: message.createdAt,
});

export const threadDetailJson = ({ thread, memos, messages }: ThreadDetail) => ({
  thread: threadJson(thread),
  memos: memos.map(memoJson),
  messages: messages.map(messageJson),
});

export const eventJson = (event: MemoEvent) => ({
  id: event.id,
  state: event.state,
  step: event.step,
  failedStep: event.failedStep,
  error: event.error,
  at: event.at,
});

/** Token presence, never the tokens: a registration response is not a place to echo credentials. */
export const deviceJson = (device: Device) => ({
  device: device.device,
  name: device.name,
  platform: device.platform,
  apnsEnv: device.apnsEnv,
  hasApnsToken: device.apnsToken !== null,
  hasPushToStartToken: device.pushToStartToken !== null,
  registeredAt: device.updatedAt,
});
