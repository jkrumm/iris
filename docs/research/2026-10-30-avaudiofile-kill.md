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
| `AVAssetWriter` with `movieFragmentInterval` is Apple's recommended crash-safe MP4, at the price of a different writer (sample buffers, async finish). | Apple docs, WWDC20 10011, the forum thread | high |

## Decision

Keep the AAC writer and the segment contract untouched. While a segment is open the recorder writes a **second file next to
it**, `<memo>-<index>.caf`: the same samples as 16 kHz mono 16-bit PCM (32 KB/s, so 320 KB per 10 s segment, deleted when the
segment closes cleanly). A kill leaves the `.m4a` unreadable and the `.caf` whole. The next launch's sweep transcodes the `.caf` to
an `.m4a` (reading it back with `AVAudioFile` and encoding with the same AAC settings), checks it plays, and from there the
file is a normal orphan: adopted by its take (the next index of a take the app died in) or kept in `quarantine/`.

Why not `AVAssetWriter` fragments: a second writer path, finish semantics and a defragmentation step to carry, and the recorder's
gapless contract rests on `AVAudioFile` writes. Why not PCM only with a transcode at close: it puts an encode (about 100 ms)
on the segment close, and every clean segment would pay for the sake of the rare kill. Why not shorter segments: the loss
shrinks but every segment is a server upload and a concat seam, and a kill still loses the open one.

What a kill still loses: samples the engine had not delivered to the tap yet (one tap buffer, 4096 frames, about 0.25 s) and
the write in flight. Disk cost while recording: 32 KB/s extra, bounded by the segment length.

## Not proven here

- Process kill only; a power loss may drop pages the OS had not written (not the case Wave 17 D2.8 tested).
- iOS file-protection class: the capture directory must stay readable after the first unlock for a background relaunch (the
  segment files have the same constraint today).
- The device kill test (D1 re-test) is the proof on hardware: force-quit mid-segment, relaunch, the memo holds the tail.
