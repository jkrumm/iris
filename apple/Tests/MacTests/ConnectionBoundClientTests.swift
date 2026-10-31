import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import IrisMac

@Suite("Connection-bound client")
struct ConnectionBoundClientTests {
  private func request() -> CreateTextMemoRequest {
    CreateTextMemoRequest(
      id: UUID().uuidString.lowercased(), mode: .auto, startedAt: Date(timeIntervalSince1970: 0), text: "hello",
      threadId: nil)
  }

  @Test("a create answered after the connection moved to another server is refused, not returned")
  func staleCreateIsRefused() async throws {
    let fake = FakeAPIClient()
    let epoch = ConnectionEpoch()
    let client = ConnectionBoundClient(base: fake, epoch: epoch)
    let gate = await fake.hold(.createTextMemo)
    let call = Task { try await client.createTextMemo(request()) }
    await gate.waitUntilHeld()
    epoch.advance()  // the saved connection changes while the old server is still answering
    await gate.release()
    await #expect(throws: APIError.transport(.cancelled)) { try await call.value }
  }

  @Test("a create that finishes under the same connection returns its memo")
  func currentCreateIsReturned() async throws {
    let client = ConnectionBoundClient(base: FakeAPIClient(), epoch: ConnectionEpoch())
    let sent = request()
    #expect(try await client.createTextMemo(sent).id == sent.id)
  }

  @Test("the refusal is a transient transfer error, so the outbox sends the item again")
  func refusalIsARetry() {
    #expect(APIOutboxUploader.classified(APIError.transport(.cancelled)) is TransientTransferError)
  }
}
