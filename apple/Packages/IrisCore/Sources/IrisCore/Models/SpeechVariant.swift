/// Which spoken form of a reply `GET /v1/memos/:id/speech?variant=` returns (the wire type is ``SpeechQuery``, covered by the
/// fixtures). Without a variant the server picks its default, which shipped apps, the auto-read and `PlayReplyIntent` use.
public typealias SpeechVariant = SpeechQuery.Variant
