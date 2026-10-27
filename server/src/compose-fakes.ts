import { ffmpegCombiner } from "./adapters/audio-gateway.js";
import type { AudioCombiner } from "./ports/audio.js";
import {
  fakeDestination,
  fakeHerd,
  fakeNotifier,
  fakeSpeaker,
  fakeSpeechCache,
  fakeSummarizer,
  fakeTranscriber,
} from "./ports/fakes.js";
import type { HerdTab } from "./ports/herd.js";

// One MPEG-1 Layer III frame (128 kbps, 44.1 kHz, 417 bytes) of silence: sniffs as audio/mpeg.
const MP3_FRAME = new Uint8Array(417);
MP3_FRAME.set([0xff, 0xfb, 0x90, 0x00]);

const TABS: HerdTab[] = [
  { id: "w1:t1", repo: "example-app", label: "server", agentState: "working", lastActivity: null },
  { id: "w2:t1", repo: "example-infra", label: "1", agentState: "idle", lastActivity: null },
  { id: "w3:t1", repo: "example-docs", label: "2", agentState: "blocked", lastActivity: null },
];

/**
 * Every downstream port as a deterministic in-memory fake (`IRIS_FAKES=1`, see `make e2e`).
 * The combiner stays real ffmpeg so `/audio` serves genuine m4a with working Range; tests inject
 * a fake one.
 */
export function composeFakes(options: { combiner?: AudioCombiner } = {}) {
  return {
    transcriber: fakeTranscriber(),
    destination: fakeDestination(),
    summarizer: fakeSummarizer(),
    notifier: fakeNotifier(),
    speaker: fakeSpeaker({ result: { bytes: MP3_FRAME } }),
    speechCache: fakeSpeechCache(),
    herd: fakeHerd({ tabs: TABS }),
    combiner: options.combiner ?? ffmpegCombiner,
  };
}
