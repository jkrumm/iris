# fixtures/audio

`de-90s.m4a`: 96 s of German speech, AAC mono 24 kHz m4a. It is the input of `make smoke` (real downstreams, mini only) and `make e2e`
(fake-booted server, CI). It is **synthetic**: audio-gateway Gemini TTS, voice `Charon`, not a human recording, so it says nothing about
microphone noise or accents. Generated in Wave 4; the original script text was not kept.

Regenerate (the output differs from the committed file, so only do it on purpose; the recipe was re-run on 2026-10-27 with a short input):

```bash
U=$(secrets-run read op://mini/iris/audio-gateway-url)        # mini; never `op`
curl -s -X POST "$U/v1/audio/speech" -H 'content-type: application/json' -H 'x-audio-source: iris' \
  -d "$(jq -n --rawfile t script.txt '{input:$t, voice:"Charon", response_format:"mp3"}')" -o speech.mp3
ffmpeg -y -i speech.mp3 -ac 1 -c:a aac -b:a 32k de-90s.m4a
```

`x-audio-source: iris` tags the call in the gateway's logs and spend. Keep the file under a few hundred KB: `send-memo.ts` splits it into 10 s
segments and the e2e uploads all of them. No real names, hosts or personal data in the script text (public repo).
