# What a killed AVAudioFile leaves on disk (Wave 18 I2)

Question: Wave 17 D2.8 force-quit a take and lost the segment in progress (about 5–8 s). What does `AVAudioFile` writing AAC
(`kAudioFormatMPEG4AAC`, 16 kHz mono, 32 kbps) leave behind at a SIGKILL, and can the next launch get it back?

Sources: `agw research` run `01a18e58-3b7e-7323-ad48-e8313fffa695` (standard depth) and a kill experiment on macOS 26 with the
same writer settings the recorder uses. Both agree.

## Findings

| Claim | Evidence | Confidence |
|-|-|-|
| An AAC `.m4a` is a non-fragmented MP4: `ftyp`, `moov`, a `free` pad, then `mdat`. The `moov` (the sample index) is written at close, which happens when the `AVAudioFile` is released (`close()` exists from iOS 18 / macOS 15). | `AVAudioFile.close()` docs; Apple Developer Forums thread 720691 ("the MOOV atom is missing" after a crash) | high |
| Killed mid-write, the file is `ftyp` + zeroes up to byte 24 576, then raw AAC access units with no framing. No `moov`, no `mdat` header. | Experiment: 3 s and 8 s of noise written, SIGKILL, hexdump + box walk | high (measured) |
| The AAC payload is flushed as it is written: the killed 8 s file held 32 703 of the 33 314 payload bytes a clean close produced (about 0.15 s missing). | Experiment | high (measured) |
| `AVAudioFile(forReading:)` fails on it (error `1685348671`, `dta?`), `ffprobe` says `moov atom not found`. A lone `.m4a` cannot be repaired without a decoder-aware frame scanner. | Experiment; untrunc / m4a-missing-moov-recoverer exist but need a reference clip or FAAD2 | high / medium |
| AAC in a `.caf` is no way out: the packet table (`pakt`) is written at close, so a killed AAC `.caf` reads as 0 frames. | Experiment (`AVAudioFile` reads 0 frames, `ffprobe`: "Missing packet table") | high (measured) |
| 16-bit linear PCM in a `.caf` survives a kill whole: the data chunk runs to end of file and the header is written up front. A killed 8.1 s file read back with all 129 600 frames, the same file a clean close gives. | Experiment; CAF spec (`mChunkSize = -1`) | high (measured) |
| `AVAssetWriter` with `movieFragmentInterval` is Apple's recommended crash-safe MP4, at the price of a different writer (sample buffers, async finish). Measured below: it survives a kill. | Apple docs, WWDC20 10011, the forum thread | high |

## Experiment 2: a fragmented m4a through `AVAssetWriter` (Wave 18 I2, second attempt)

The first attempt (a PCM shadow `.caf` beside every open segment, transcoded back by the sweep) needed recovery, ownership and
sweep machinery that did not converge in review. The simpler design is a writer whose own file survives a kill:
`AVAssetWriter(fileType: .m4a)` with `movieFragmentInterval` set, AAC 16 kHz mono 32 kbps (the recorder's exact settings),
PCM sample buffers appended in real time in 4096-frame chunks as the tap delivers them. A child process writes; the parent sends
`kill -9` at a chosen moment; then `AVURLAsset` (duration + `AVAssetReader` decode), `AVAudioFile(forReading:)` and `ffprobe`
read the file. macOS 26 host, 2026-10-31.

| Writer | Fragment interval | Killed at | Written when killed | Kept (decoded) | Readers |
|-|-|-|-|-|-|
| `AVAudioFile` (today's) | none | 5.5 s | 4.1 s | **0 s** | `AVURLAsset` "Cannot Open", `AVAudioFile` error, ffprobe "moov atom not found" |
| `AVAssetWriter` | 0.25 s | 4 s / 7.3 s | 2.82 s / 5.12 s | 2.62 s / 4.92 s | all three read it |
| `AVAssetWriter` | 0.5 s | 4 s / 7.3 s | 3.07 s / 5.38 s | 2.88 s / 4.92 s | all three read it |
| `AVAssetWriter` | 1 s | 4 s / 7.3 s | 2.82 s / 5.38 s | 1.92 s / 4.92 s | all three read it |
| `AVAssetWriter` | 2 s | 4 s / 7.3 s | 3.07 s / 5.12 s | 1.92 s / 3.90 s | all three read it |

A fragmented file keeps everything but the open fragment and the encoder's latency; at 0.5 s that is 0.2–0.45 s measured. The
file is `ftyp`, then `mdat` and `moof` pairs, each fragment carrying its own sample table, so there is no trailer to lose. Cutting
a killed file at 29 byte offsets (a kill between the writes of one fragment) always read back as a prefix on a whole
fragment boundary, or as nothing before the first fragment's end (about 2.9 KB, 0.4 s of audio): nothing misread, nothing throws.

The server contract holds. The file name (`<memo>-<index>.m4a`) and `audio/mp4` are unchanged. The server's own command
(`ffmpeg -f concat -safe 0 -i list -vn -ac 1 -ar 16000 -c:a aac -b:a 32k -movflags +faststart`) joined a finished fragmented
segment (3.26 s by ffprobe), a **killed** one (4.03 s) and a plain `AVAudioFile` one (3.26 s) into one file of 10.43 s, exit 0.
Seams: `ffprobe` reports the same priming (`start_time=0.132`, 51 packets for 3 s) for a plain and a fragmented segment, and two
of each concatenate to the same 6.144 s, so the swap adds no gap at a seam.

## Decision

Segments are written by `SegmentWriter`, an `AVAssetWriter` fragmented m4a (`movieFragmentInterval` 0.5 s), instead of an
`AVAudioFile`. The segment contract (name, `audio/mp4`, rotation, the outbox, the server concat) is untouched. There is **no
recovery code**: the startup sweep already adopts a file the production inspector (`AVAudioFile(forReading:)`) reads, so a killed
tail is adopted like any orphan (the next index of a take the app died in) and sent with the memo; a file that does not read
(killed before the first fragment) is set aside in `quarantine/`, never deleted. A segment is queued only after its writer has
finished and the file reads back. A file that ends where the encoder stopped is queued with the duration it holds and fails the
take; one that does not read back is left on disk and fails it; either way no later segment of the take is queued, so the
outbox never waits for a missing index. A take killed in its first segment is the common case (the first 10 s of every take):
the startup recovery used to drop a take with no queued segment before the sweep ran, which quarantined the playable file;
it now keeps the item, hidden, until the sweep has attached index 0.

Why not the shadow design: a second file per open segment, a transcode at launch and the rules for who owns, replaces or deletes
what (nine data-safety findings per review round on the parked branch). Why not PCM only with a transcode at close: an encode
(about 100 ms) on every segment close for the rare kill. Why not shorter segments: the loss shrinks, every segment is still an
upload and a concat seam, and a kill still loses the open one.

What a kill still loses: the open fragment and the encoder's latency (0.2–0.5 s measured at 0.5 s fragments), plus samples the
engine had not delivered to the tap yet (one tap buffer, 4096 frames, about 0.25 s). Cost: fragment headers every 0.5 s
(a 3 s segment: 16.1 KB against 14.5 KB, about 10 % more upload), and a close that is asynchronous (`finishWriting`), so the recorder queues a segment
a moment after the rotation, in order, and `stop()` waits for the last one.

## Not proven here

- Process kill only; a power loss may drop pages the OS had not written (not the case Wave 17 D2.8 tested).
- iOS file-protection class: the capture directory must stay readable after the first unlock for a background relaunch (the
  segment files have the same constraint today).
- iOS's `AVAssetWriter` fragment flush timing: measured on macOS 26 only. The device kill test (checklist row 8a) is the proof on hardware: force-quit mid-segment, relaunch, the memo holds the tail.
