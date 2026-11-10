import Foundation

/// A deterministic, realistic assistant reply (~16 000 characters) and the growing prefixes a
/// streaming consumer would receive. Foundation only, no dependency on the rest of the package,
/// so the file can be copied verbatim into another package.
public enum ProseFixture {
    /// Growing prefixes in `step`-character increments; the last one is the full reply.
    public static func snapshots(step: Int = 20) -> [String] {
        precondition(step > 0)
        let characters = Array(reply)
        var result: [String] = []
        var end = step
        while end < characters.count {
            result.append(String(characters[0 ..< end]))
            end += step
        }
        result.append(reply)
        return result
    }

    public static let reply: String = [
        intro, lists, table, swiftCode, math, jsonAndShell, quote, testing, wideCode, closing,
    ].joined(separator: "\n\n")

    private static let intro = #"""
    # Designing a voice memo pipeline

    You asked how to structure a pipeline that takes a recorded voice memo from the phone to a set of structured actions on the server. Below is a walkthrough of the stages, the trade-offs I would make, and the pieces of code that matter. I kept the examples close to what a small **Bun + SQLite** service would look like, because that keeps the moving parts few and the failure modes easy to reason about.

    ## Overview

    A memo travels through five stages: *capture*, *upload*, *transcribe*, *classify* and *act*. Each stage is a pure function of the previous stage's output plus a small amount of configuration, which makes every stage retryable on its own. The most common mistake is to couple two stages through shared mutable state; the second most common is to hide a network call inside a function that looks pure. See the [Swift concurrency guide](https://developer.apple.com/documentation/swift/concurrency) for the isolation rules that apply on the client, and the [SQLite WAL documentation](https://www.sqlite.org/wal.html) for the server side.

    The short version of the argument is this: **make every step idempotent**, *record every transition*, and keep `status` a closed set. A memo that is stuck should always be explainable by one row in one table. Anything else turns debugging into archaeology, and archaeology does not scale past the first on-call night.

    ### Why stages instead of one job

    One big job is simpler to write and much harder to operate. When the transcription provider has a bad hour, a single job fails as a whole and you re-run the upload too, which wastes bandwidth and, worse, creates duplicates when the upload is not idempotent. With separate stages the failure is local, the retry is local, and the metrics tell you which provider is slow without any log spelunking.

    ### What each stage owns

    Every stage owns exactly one table column group and one external dependency. Capture owns the audio file on the device, upload owns the object key, transcribe owns the text and the language tag, classify owns the kind and the confidence, and act owns the list of created actions. If a stage needs data from two places, that is a sign that a stage boundary is in the wrong spot.
    """#

    private static let lists = #"""
    ## Stages and their failure modes

    1. **Capture** on the device
       1. Start the recording from the Lock Screen control or the Action button.
          - Keep the audio session category stable for the whole take.
          - Never change the route while a take is running.
          - Write the file into the shared container, not into a temporary directory.
       2. Stop on silence only if the user opted in.
          - A fixed timeout of three seconds works for most people.
          - Offer a manual stop on the Live Activity.
       3. Persist a small manifest next to the audio.
          - The memo identifier, created at the moment of the first sample.
          - The duration, the sample rate and the codec.
    2. **Upload** to the server
       1. Use a background `URLSession` so the transfer survives the app being suspended.
          - Set the identifier per memo, so a relaunch can reattach.
          - Prefer `multipart/form-data` with the manifest as the first part.
       2. Treat a `409` as success when the identifier already exists.
          - The body of a `409` carries the stored status, which the client should show.
    3. **Transcribe** on the server
       1. Send the file to the provider with a language hint when you know one.
          - A wrong hint is worse than none; leave it empty if unsure.
       2. Store the raw text and a cleaned variant.
          - Keep the raw text forever; it is cheap and it is the only ground truth.
          - The cleaned variant strips filler words and fixes obvious casing.
    4. **Classify** the memo into one of a small set of kinds
       1. Ask for a closed enumeration, never free text.
          - Reject anything outside the set and retry once with a stricter prompt.
       2. Record the confidence next to the kind.
    5. **Act** by creating tasks, notes or reminders
       1. Create each action in its own transaction.
          - If one action fails, the others stay created and the memo is marked partial.

    The list above looks long, but each leaf is a decision you will otherwise make at two in the morning. Writing it down once is cheaper. A few additional rules that apply to every stage:

    - Log the **memo identifier** and the **stage name** on every line, nothing else is needed to correlate.
    - Emit one span per stage with the attempt number as an attribute.
    - Use `Retry-After` when the provider sends it, otherwise back off with jitter.
      - Start at two seconds and double up to a ceiling of two minutes.
      - Give up after six attempts and mark the memo `failed(<stage>)`.
        - A failed memo stays visible in the app with a retry button.
        - A retry re-enters the failed stage, never an earlier one.
    - Prefer ~~polling~~ a push notification for the final status, and fall back to polling only while the app is in the foreground.
    """#

    private static let table = #"""
    ## Provider comparison

    I measured four transcription providers on the same forty memos, a mix of German and English, between ten seconds and four minutes long. The numbers are medians; the cost is per audio hour at list price.

    | Provider | Median latency | Word error rate | Languages | Cost per hour |
    |:--|:-:|--:|:-:|--:|
    | Provider A | 3.2 s | 6.1 % | 98 | $0.36 |
    | Provider B | 1.9 s | 7.4 % | 52 | $0.24 |
    | Provider C | 5.8 s | 4.9 % | 100 | $0.60 |
    | Provider D | 2.4 s | 8.8 % | 31 | $0.18 |
    | On-device model | 7.1 s | 9.5 % | 12 | $0.00 |
    | Provider A (batch) | 41.0 s | 5.7 % | 98 | $0.12 |
    | Provider B (batch) | 29.5 s | 7.0 % | 52 | $0.09 |
    | Provider C (streaming) | 0.9 s | 6.6 % | 100 | $0.72 |

    Two things stand out. The cheapest option is not the worst one, and the best word error rate costs about three times as much as the cheapest. For short memos, latency dominates the experience, so Provider B wins on feel even though Provider C wins on accuracy. A sentence about money, to check that dollar signs survive: a coffee costs $5 and $10 buys lunch, neither of which is math.
    """#

    private static let swiftCode = #"""
    ## The client side

    The upload manager is a small actor. It owns the background session, maps task identifiers back to memos and publishes progress. The important detail is that the delegate callbacks arrive on an arbitrary queue, so the actor never touches the session from inside a callback.

    ```swift
    import Foundation

    actor UploadManager {
        struct Progress: Sendable {
            let memoID: UUID
            let sent: Int64
            let total: Int64
        }

        private let session: URLSession
        private var tasks: [Int: UUID] = [:]
        private var continuations: [UUID: AsyncStream<Progress>.Continuation] = [:]

        init(configuration: URLSessionConfiguration) {
            session = URLSession(configuration: configuration)
        }

        func upload(memoID: UUID, file: URL, to endpoint: URL) throws -> AsyncStream<Progress> {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "PUT"
            request.setValue(memoID.uuidString, forHTTPHeaderField: "Idempotency-Key")

            let task = session.uploadTask(with: request, fromFile: file)
            tasks[task.taskIdentifier] = memoID
            task.resume()

            return AsyncStream { continuation in
                continuations[memoID] = continuation
                continuation.onTermination = { [weak task] _ in task?.cancel() }
            }
        }

        func report(taskID: Int, sent: Int64, total: Int64) {
            guard let memoID = tasks[taskID] else { return }
            continuations[memoID]?.yield(Progress(memoID: memoID, sent: sent, total: total))
        }

        func finish(taskID: Int) {
            guard let memoID = tasks.removeValue(forKey: taskID) else { return }
            continuations.removeValue(forKey: memoID)?.finish()
        }
    }
    ```

    Note the `onTermination` handler: without it, a view that stops listening leaves the transfer running, which is exactly what you want for a background upload but not for a foreground preview. Decide which one you mean and write it down.
    """#

    private static let math = #"""
    ## A word on estimating cost

    The transcription bill is linear in audio duration, so a back-of-the-envelope model is enough. Let $E=mc^2$ stand for nothing here; the only formula that matters is the monthly cost, where \(c\) is the price per hour, \(n\) the memos per day and \(d\) the mean duration in minutes: \(C = 30 \cdot n \cdot d \cdot c / 60\). With forty memos a day of two minutes each at the cheapest rate that comes to a little over two euros a month, which is below the noise of every other line item.

    The tail matters more than the mean. If durations follow a heavy-tailed distribution, a single long recording can cost as much as a hundred short ones. A convenient closed form that shows up in many such models is the Gaussian integral:

    $$\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt\pi}{2}$$

    You do not need it for the pricing itself, but it is a good smoke test for a math renderer: if that line renders as a tidy fraction with a square root and not as raw source, the pipeline from parser to typesetter works.
    """#

    private static let jsonAndShell = #"""
    ## The server contract

    The server answers every request about a memo with the same envelope, so the client can render any state from one decoder. A memo in the middle of the pipeline looks like this:

    ```json
    {
      "id": "6f1d0a52-8b31-4c8e-9f55-0b6c1e8a7d10",
      "status": "transcribed",
      "createdAt": "2026-11-10T08:14:03Z",
      "durationSeconds": 74.5,
      "language": "de",
      "steps": [
        { "name": "upload", "state": "done", "attempts": 1, "ms": 812 },
        { "name": "transcribe", "state": "done", "attempts": 2, "ms": 4311 },
        { "name": "classify", "state": "pending", "attempts": 0, "ms": null }
      ],
      "actions": []
    }
    ```

    To inspect one by hand, fetch it and pick out the step that is stuck. The command assumes the token is already in your environment:

    ```sh
    curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/memos/$ID" \
      | jq -r '.steps[] | select(.state != "done") | "\(.name)\t\(.state)\t\(.attempts)"'

    # retry the failed stage, never an earlier one
    curl -sS -X POST -H "Authorization: Bearer $TOKEN" "$BASE/memos/$ID/retry"
    ```

    Keep the envelope stable. Adding a field is free; renaming one is a migration that touches every client you ever shipped.
    """#

    private static let quote = #"""
    ## Operating it

    > The best retry policy is the one you never have to think about. If a stage can be run twice with the same effect as once, then "did it run?" stops being a question and "is the state right?" takes its place.
    >
    > A second paragraph inside the quote, with **strong** text, some `inline code` and a [link](https://example.com/retries), to check that nested inline styling survives.

    There are three dashboards worth building before the first user arrives. The first is a plain count of memos per status, which tells you whether anything is piling up. The second is the age of the oldest memo that is not in a final status, which tells you whether something is stuck. The third is the attempt histogram per stage, which tells you which dependency is flaky before your users do.

    ### Alerting without noise

    Alert on the age of the oldest unfinished memo, not on error counts. A burst of errors that the retry policy absorbs is not an incident; a memo that has been unfinished for twenty minutes always is. This one rule replaces a page of threshold tuning, and it keeps working when you swap a provider and the error signature changes.

    ### Capacity

    A single small VPS comfortably handles tens of thousands of memos a day, because the heavy work happens at the providers. The local costs are the audio files on disk and the SQLite write-ahead log. Rotate the files by age after the transcript is stored, keep the raw text, and checkpoint the log on a timer.
    """#

    private static let testing = #"""
    ## Testing it

    The pipeline is easy to test because every adapter sits behind a small interface. I would write the tests in three layers and resist the urge to add a fourth:

    1. **Unit tests** for the pure parts
       1. The transition table: every legal edge passes, every other pair of statuses is rejected.
          - Generate the illegal pairs instead of listing them, so a new status cannot be forgotten.
       2. The envelope encoder and decoder, round-tripped through a fixture file.
          - Keep one fixture per status; they double as documentation.
    2. **Contract tests** for each adapter
       1. Run the same suite against the fake and against the real adapter behind a flag.
          - The fake must fail in the same ways: a timeout, a rate limit and a malformed body.
       2. Record real responses once and replay them in CI.
    3. **One end-to-end test** with everything fake-booted
       1. Feed a short audio file in, wait for the final status, assert the actions.
          - Assert the *shape* of the result, not the exact words of the transcript.

    A rule of thumb that has saved me more than once: if a bug needed a production incident to find, the fix comes with a test at the lowest layer that could have caught it, and the incident gets a one-line entry in the runbook. That is cheap, and after a few months the runbook is the best documentation the system has.

    Two smaller habits help as well. First, name tests after the behaviour (`retriesOnlyTheFailedStage`), not the function. Second, keep the clock injectable from day one; retrofitting it later touches every file, and a test that sleeps is a test that eventually gets deleted.
    """#

    private static let wideCode = #"""
    ## Wiring it together

    The composition root is the one place that knows every adapter. It is long on purpose; the line that builds the transcription adapter is wider than a phone screen, so a renderer has to scroll it rather than wrap it.

    ```swift
    let pipeline = Pipeline(steps: [UploadStep(store: store), TranscribeStep(provider: TranscriptionAdapter(endpoint: environment.transcriptionEndpoint, apiKey: environment.transcriptionKey, languageHint: nil, timeout: .seconds(90), retryPolicy: .exponential(base: .seconds(2), ceiling: .seconds(120), attempts: 6))), ClassifyStep(model: classifier), ActStep(actions: actionFactory)], clock: ContinuousClock(), recorder: recorder)
    ```

    In tests the same function takes fakes for every adapter and a manual clock, so the whole pipeline runs in a few milliseconds and the retry schedule can be asserted without sleeping.
    """#

    private static let closing = #"""
    ## Summary and next steps

    To pull it together, here is the order I would build things in, from the cheapest guarantee to the most expensive one:

    1. Define the status set and the transition table, and reject every other transition in code.
    2. Write the envelope and its decoder before any endpoint, then generate the client types from it.
    3. Build the upload with an idempotency key and test the duplicate path first.
    4. Add transcription behind an interface with a fake, so everything downstream can be tested offline.
    5. Add classification with a closed enumeration and a strict retry.
    6. Add actions last; they are the only stage with user-visible side effects.

    Once those exist, the remaining work is mostly *observability* and *polish*: the dashboards above, a retry button in the app, and a short runbook that starts with "fetch the memo, read the step timeline". If you want, I can sketch the transition table and the matching test cases next, or go deeper on the background session handling, which is the part that most often surprises people in production.

    ---

    Finally, a short list of things I would deliberately **not** build yet:

    - A plug-in system for stages. Five stages do not need one.
    - A generic workflow engine. The status set is the engine.
    - Per-user routing of providers. Measure first; the table above says the differences are small.
    - Client-side classification. It saves a round trip and costs you every future model upgrade.

    That is the whole picture. The pipeline is boring by design, and that is the point: the interesting parts of the product live in what the actions do for the person who spoke, not in how the bytes get there.
    """#
}
